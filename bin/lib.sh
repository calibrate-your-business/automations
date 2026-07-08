#!/usr/bin/env bash
# bin/lib.sh -- shared core for the automations manager.
#
# Two roles:
#   1. Sourced library. install/status/uninstall/refresh/bootstrap source this
#      for the .autojob parser, the scheduler backend (unit rendering + the
#      sched_* interface), registration + job discovery.
#   2. Scheduler runtime entrypoint. Rendered units call
#      `bash lib.sh run <abs-path-to-autojob>`; that sets up logging, runs the
#      job's COMMAND, writes a last-success marker, and notifies on failure.
#
# Self-locating: AUTO_MANAGER_ROOT is derived from this file's path
# ($AUTO_MANAGER_ROOT/bin/lib.sh), never from cwd, so it works under launchd or
# systemd where cwd is undefined.
#
# Model: this repo (the MANAGER) holds only registrations + tooling. The job
# definitions (*.autojob) live in the registered SOURCE repos, in an
# automations/ dir at whatever level owns the work, discovered on disk.
#
# Cross-platform: the scheduler, notifier, and path resolution are abstracted
# behind a platform layer (see AUTO_OS below and the "scheduler backend"
# section). macOS is backed by launchd; Linux by systemd user timers. The
# .autojob schema, discovery, and commit-mode model are platform-neutral.
#
# ASCII-only. No external state beyond the platform unit dir and log base
# resolved below (AUTO_UNIT_DIR / AUTO_LOG_BASE).

set -uo pipefail

AUTO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # .../automations/bin
AUTO_MANAGER_ROOT="$(cd "$AUTO_LIB_DIR/.." && pwd)"               # .../automations
AUTO_REG_DIR="$AUTO_MANAGER_ROOT/registrations"
# Source-repo checkouts live as SIBLINGS of this manager: <parent>/<NAME>.
# Override with AUTO_REPOS_HOME in the environment if yours live elsewhere.
AUTO_REPOS_HOME="${AUTO_REPOS_HOME:-$(dirname "$AUTO_MANAGER_ROOT")}"

# ---------------------------------------------------------------------------
# platform resolution (path/dir + PATH; FUTURE-WORK item 3)
# ---------------------------------------------------------------------------
# AUTO_OS drives every platform branch below and in the scheduler/notifier.
case "$(uname -s)" in
  Darwin) AUTO_OS="darwin" ;;
  Linux)  AUTO_OS="linux"  ;;
  *)      AUTO_OS="unknown" ;;
esac

# The scheduler hands jobs a minimal PATH. Jobs need tools that live outside it
# (sops, gcloud, jq, node, claude). Establish a known-good PATH per platform.
# AUTO_LOG_BASE = where per-job logs + last-success markers live.
# AUTO_UNIT_DIR = where scheduler unit files live (launchd plists / systemd units).
if [[ "$AUTO_OS" == "darwin" ]]; then
  AUTO_LOG_BASE="$HOME/Library/Logs/automations"
  AUTO_UNIT_DIR="$HOME/Library/LaunchAgents"
  AUTO_PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  # Linux (and unknown fallback): XDG base dirs.
  AUTO_LOG_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/automations"
  AUTO_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  AUTO_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/snap/bin"
fi

# Manifest lives alongside the units so a machine's installed-job record sits
# with its scheduler state. On darwin this resolves to LaunchAgents (unchanged).
AUTO_MANIFEST="$AUTO_UNIT_DIR/.automations-manifest"
AUTO_GUI_DOMAIN="gui/$(id -u)"                                    # launchd only

# RUNTIME=claude permissioning: a scheduled headless run cannot answer prompts,
# so pre-approve exactly the tool set an analysis/report job needs and nothing
# else. Bounded blast radius without a brittle per-command allowlist.
AUTO_CLAUDE_ALLOWED_TOOLS="Read Edit Write Bash Glob Grep"

# ---------------------------------------------------------------------------
# registration parsing
# ---------------------------------------------------------------------------
# Echo the value of KEY from a registration (.repo) or any KEY=value file.
# First '=' splits; '#'-comments and blanks ignored. Prints nothing if absent.
reg_field() {
  local file="$1" want="$2" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" == "$want" ]] && { echo "$val"; return 0; }
  done < "$file"
}

# ---------------------------------------------------------------------------
# .autojob parsing
# ---------------------------------------------------------------------------
# Parse a .autojob file into the JOB_* globals. Returns non-zero (and prints to
# stderr) if a required field is missing or RUNTIME is invalid. Never sources
# the file (no code execution); reads KEY=value lines, '#'-comments and blanks
# ignored. The first '=' splits key from value, so values may contain '='.
parse_job() {
  local jobfile="$1"
  JOB_FILE="$jobfile"
  JOB_DIR="$(cd "$(dirname "$jobfile")" && pwd)"
  JOB_LABEL=""
  JOB_SCHEDULE=""
  JOB_RUNTIME=""
  JOB_COMMAND=""
  JOB_WORKDIR=""
  JOB_MODEL=""
  JOB_ENABLED="true"

  if [[ ! -f "$jobfile" ]]; then
    echo "automations: job file not found: $jobfile" >&2
    return 1
  fi

  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolerate CRLF
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"       # ltrim key
    key="${key%"${key##*[![:space:]]}"}"        # rtrim key
    case "$key" in
      LABEL)    JOB_LABEL="$val" ;;
      SCHEDULE) JOB_SCHEDULE="$val" ;;
      RUNTIME)  JOB_RUNTIME="$val" ;;
      COMMAND)  JOB_COMMAND="$val" ;;
      WORKDIR)  JOB_WORKDIR="$val" ;;
      MODEL)    JOB_MODEL="$val" ;;
      ENABLED)  JOB_ENABLED="$val" ;;
      *) echo "automations: unknown key '$key' in $jobfile (ignored)" >&2 ;;
    esac
  done < "$jobfile"

  local missing=()
  [[ -z "$JOB_LABEL" ]]    && missing+=("LABEL")
  [[ -z "$JOB_SCHEDULE" ]] && missing+=("SCHEDULE")
  [[ -z "$JOB_RUNTIME" ]]  && missing+=("RUNTIME")
  [[ -z "$JOB_COMMAND" ]]  && missing+=("COMMAND")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "automations: $jobfile missing required field(s): ${missing[*]}" >&2
    return 1
  fi
  case "$JOB_RUNTIME" in
    script|claude) ;;
    *) echo "automations: $jobfile has invalid RUNTIME '$JOB_RUNTIME' (script|claude)" >&2; return 1 ;;
  esac
  # MODEL only means something to the claude runtime. Warn-and-ignore rather
  # than fail so a job can flip RUNTIME without tripping over a stale MODEL.
  if [[ -n "$JOB_MODEL" && "$JOB_RUNTIME" != "claude" ]]; then
    echo "automations: $jobfile sets MODEL but RUNTIME=$JOB_RUNTIME (only meaningful for claude; ignored)" >&2
    JOB_MODEL=""
  fi
  if [[ ! "$JOB_SCHEDULE" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    echo "automations: $jobfile has invalid SCHEDULE '$JOB_SCHEDULE' (want HH:MM)" >&2
    return 1
  fi
  return 0
}

# Echo the schedule's hour and minute as decimal integers (strips leading
# zeros so the plist gets valid <integer>s, not octal).
schedule_hour() { local s="$1"; echo "$(( 10#${s%%:*} ))"; }
schedule_min()  { local s="$1"; echo "$(( 10#${s##*:} ))"; }

# ---------------------------------------------------------------------------
# discovery: registrations -> source-repo roots -> *.autojob
# ---------------------------------------------------------------------------
# The owning repo root of an .autojob = the nearest ancestor dir containing .git
# (a dir OR a worktree's .git file). COMMAND/WORKDIR resolve against this.
owning_root() {
  local d="$1"
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -e "$d/.git" ]] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  echo "$d"
}

# Print each registered source-repo checkout that exists on disk. A registration
# is registrations/<name>.repo with NAME=<name>; the checkout is the sibling
# <repos-home>/<NAME>. Reads registrations off disk, so a gitignored (local-only)
# registration works exactly like a committed one.
registered_roots() {
  local reg name root
  for reg in "$AUTO_REG_DIR"/*.repo; do
    [[ -f "$reg" ]] || continue
    name="$(reg_field "$reg" NAME)"
    [[ -n "$name" ]] || continue
    root="$AUTO_REPOS_HOME/$name"
    [[ -e "$root/.git" ]] && echo "$root"
  done
}

# Print (one per line) every automations/*.autojob under each registered root.
# Skips .git. Stable, de-duplicated by path.
discover_jobs() {
  local r
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    find "$r" -type d -name .git -prune -o \
         -type f -path '*/automations/*.autojob' -print 2>/dev/null
  done < <(registered_roots) | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# scheduler backend: unit rendering (FUTURE-WORK item 1)
# ---------------------------------------------------------------------------
# Two renderers, one per platform, each emitting the scheduler unit(s) for the
# currently-parsed job to stdout. Both point the scheduler at the same runtime
# entrypoint: `bash lib.sh run <JOB_FILE>`.

# macOS/launchd. No RunAtLoad: jobs fire only on their StartCalendarInterval.
# launchd runs a missed slot once on next wake.
render_plist() {
  local hour min launchlog
  hour="$(schedule_hour "$JOB_SCHEDULE")"
  min="$(schedule_min "$JOB_SCHEDULE")"
  launchlog="$AUTO_LOG_BASE/$JOB_LABEL/$JOB_LABEL.launchd.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$JOB_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$AUTO_LIB_DIR/lib.sh</string>
        <string>run</string>
        <string>$JOB_FILE</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$hour</integer>
        <key>Minute</key>
        <integer>$min</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$launchlog</string>
    <key>StandardErrorPath</key>
    <string>$launchlog</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
}

# Linux/systemd user timer. A oneshot .service does the work; a .timer with
# OnCalendar schedules it. Persistent=true replays a missed slot on next boot
# (the launchd "missed slot on next wake" analog; FUTURE-WORK item 6). The pair
# is rendered into AUTO_UNIT_DIR as <label>.service and <label>.timer.
render_service() {
  cat <<UNIT
[Unit]
Description=automations job $JOB_LABEL
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $AUTO_LIB_DIR/lib.sh run $JOB_FILE
UNIT
}

render_timer() {
  # OnCalendar wants HH:MM:SS in local time. JOB_SCHEDULE is validated HH:MM.
  cat <<UNIT
[Unit]
Description=automations timer for $JOB_LABEL

[Timer]
OnCalendar=*-*-* $JOB_SCHEDULE:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
}

# ---------------------------------------------------------------------------
# scheduler backend: install / remove / state / health interface
# ---------------------------------------------------------------------------
# The bin/ scripts speak only to these four verbs; each dispatches on AUTO_OS.
#
#   sched_install         -- render + load unit(s) for the parsed JOB_* globals.
#                            Prints an "installed ..." line on success; returns
#                            non-zero (with detail on stderr) on failure.
#   sched_remove <label>  -- unload + delete a label's unit(s). Idempotent.
#   sched_state <label>   -- print a one-word scheduler state for `status`.
#   sched_health <label>  -- print "ok" or "BROKEN:<reason>" (unit still points
#                            at a real lib.sh + .autojob).

sched_install() {
  case "$AUTO_OS" in
    darwin) _sched_install_launchd ;;
    linux)  _sched_install_systemd ;;
    *) echo "  ERROR unsupported OS '$(uname -s)' -- no scheduler backend" >&2; return 1 ;;
  esac
}

_sched_install_launchd() {
  local plist="$AUTO_UNIT_DIR/$JOB_LABEL.plist"
  mkdir -p "$AUTO_LOG_BASE/$JOB_LABEL"
  render_plist > "$plist"
  launchctl bootout "$AUTO_GUI_DOMAIN/$JOB_LABEL" >/dev/null 2>&1 || true
  local errfile; errfile="$(mktemp)"
  if launchctl bootstrap "$AUTO_GUI_DOMAIN" "$plist" 2>"$errfile"; then
    echo "  installed $JOB_LABEL ($JOB_SCHEDULE, $JOB_RUNTIME)"
    rm -f "$errfile"
  else
    echo "  ERROR bootstrapping $JOB_LABEL:" >&2
    sed 's/^/    /' "$errfile" >&2
    rm -f "$errfile"
    return 1
  fi
}

_sched_install_systemd() {
  local svc="$AUTO_UNIT_DIR/$JOB_LABEL.service"
  local tmr="$AUTO_UNIT_DIR/$JOB_LABEL.timer"
  mkdir -p "$AUTO_UNIT_DIR" "$AUTO_LOG_BASE/$JOB_LABEL"
  render_service > "$svc"
  render_timer > "$tmr"
  # daemon-reload picks up edited unit contents; reenable fixes the symlink;
  # restart re-reads OnCalendar and (re)arms the timer. All idempotent.
  systemctl --user daemon-reload
  systemctl --user reenable "$JOB_LABEL.timer" >/dev/null 2>&1 || true
  if systemctl --user restart "$JOB_LABEL.timer" 2>/tmp/auto-systemd.$$; then
    echo "  installed $JOB_LABEL ($JOB_SCHEDULE, $JOB_RUNTIME)"
    rm -f "/tmp/auto-systemd.$$"
  else
    echo "  ERROR arming $JOB_LABEL.timer:" >&2
    sed 's/^/    /' "/tmp/auto-systemd.$$" >&2
    rm -f "/tmp/auto-systemd.$$"
    return 1
  fi
}

sched_remove() {
  local label="$1"
  case "$AUTO_OS" in
    darwin)
      launchctl bootout "$AUTO_GUI_DOMAIN/$label" >/dev/null 2>&1 || true
      rm -f "$AUTO_UNIT_DIR/$label.plist"
      ;;
    linux)
      systemctl --user disable --now "$label.timer" >/dev/null 2>&1 || true
      rm -f "$AUTO_UNIT_DIR/$label.timer" "$AUTO_UNIT_DIR/$label.service"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      ;;
  esac
}

sched_state() {
  local label="$1"
  case "$AUTO_OS" in
    darwin) _sched_state_launchd "$label" ;;
    linux)  _sched_state_systemd "$label" ;;
    *) echo "no-backend" ;;
  esac
}

# Pull "last exit code = N" from `launchctl print`. Prints a status word.
_sched_state_launchd() {
  local label="$1" out
  out="$(launchctl print "$AUTO_GUI_DOMAIN/$label" 2>/dev/null)" || { echo "not-loaded"; return; }
  local exitcode
  exitcode="$(printf '%s\n' "$out" | sed -n 's/.*last exit code = \([0-9-]*\).*/\1/p' | head -1)"
  if [[ -z "$exitcode" ]]; then
    echo "loaded(norun)"
  elif [[ "$exitcode" == "0" ]]; then
    echo "loaded,exit0"
  else
    echo "loaded,EXIT$exitcode"
  fi
}

# Timer armed? Then report the service's last run result. A oneshot that never
# ran has an empty ExecMainExitTimestamp -> "loaded(norun)".
_sched_state_systemd() {
  local label="$1"
  [[ "$(systemctl --user is-active "$label.timer" 2>/dev/null)" == "active" ]] || { echo "not-loaded"; return; }
  local ran code
  ran="$(systemctl --user show "$label.service" -p ExecMainExitTimestampMonotonic --value 2>/dev/null)"
  if [[ -z "$ran" || "$ran" == "0" ]]; then
    echo "loaded(norun)"
    return
  fi
  code="$(systemctl --user show "$label.service" -p ExecMainStatus --value 2>/dev/null)"
  if [[ "$code" == "0" ]]; then
    echo "loaded,exit0"
  else
    echo "loaded,EXIT$code"
  fi
}

sched_health() {
  local label="$1"
  case "$AUTO_OS" in
    darwin) _sched_health_launchd "$label" ;;
    linux)  _sched_health_systemd "$label" ;;
    *) echo "BROKEN:no-backend" ;;
  esac
}

# Confirm the installed plist still points at a real lib.sh and a real .autojob.
_sched_health_launchd() {
  local label="$1"
  local plist="$AUTO_UNIT_DIR/$label.plist"
  [[ -f "$plist" ]] || { echo "BROKEN:no-plist"; return; }
  local lib job
  lib="$(sed -n 's|.*<string>\(.*/lib.sh\)</string>.*|\1|p' "$plist" | head -1)"
  job="$(sed -n 's|.*<string>\(.*\.autojob\)</string>.*|\1|p' "$plist" | head -1)"
  [[ -n "$lib" && -f "$lib" ]] || { echo "BROKEN:lib-missing"; return; }
  [[ -n "$job" && -f "$job" ]] || { echo "BROKEN:autojob-missing"; return; }
  echo "ok"
}

# Confirm the installed .service ExecStart still points at a real lib.sh + job,
# and that the .timer unit is present.
_sched_health_systemd() {
  local label="$1"
  local svc="$AUTO_UNIT_DIR/$label.service"
  local tmr="$AUTO_UNIT_DIR/$label.timer"
  [[ -f "$svc" ]] || { echo "BROKEN:no-service"; return; }
  [[ -f "$tmr" ]] || { echo "BROKEN:no-timer"; return; }
  local lib job
  lib="$(sed -n 's|.*ExecStart=/bin/bash \(.*/lib.sh\) run .*|\1|p' "$svc" | head -1)"
  job="$(sed -n 's|.*/lib.sh run \(.*\)$|\1|p' "$svc" | head -1)"
  [[ -n "$lib" && -f "$lib" ]] || { echo "BROKEN:lib-missing"; return; }
  [[ -n "$job" && -f "$job" ]] || { echo "BROKEN:autojob-missing"; return; }
  echo "ok"
}

# ---------------------------------------------------------------------------
# runtime: execute one job (called by launchd via `lib.sh run <jobfile>`)
# ---------------------------------------------------------------------------
# Platform notifier (FUTURE-WORK item 2). Best-effort; never let a notify
# failure mask the job's own exit code.
notify() {
  local title="$1" msg="$2"
  case "$AUTO_OS" in
    darwin) osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true ;;
    linux)  notify-send "$title" "$msg" >/dev/null 2>&1 || true ;;
  esac
}

notify_failure() {
  local label="$1" code="$2"
  notify "automation failed: $label" "exited $code -- see logs under $AUTO_LOG_BASE"
}

run_job() {
  local jobfile="$1"
  export PATH="$AUTO_PATH"

  # sops/age under launchd: SOPS_AGE_KEY_FILE is not inherited, and sops's
  # default identity search does not locate the key in this environment, so
  # decryption fails. Point it at the canonical key file when the job has not
  # already set it. Path only -- not a secret.
  if [[ -z "${SOPS_AGE_KEY_FILE:-}" && -f "$HOME/.config/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  fi

  if ! parse_job "$jobfile"; then
    [[ -n "${JOB_LABEL:-}" ]] && notify_failure "$JOB_LABEL" "parse-error"
    return 2
  fi

  local logdir="$AUTO_LOG_BASE/$JOB_LABEL"
  mkdir -p "$logdir"
  local datelog="$logdir/$JOB_LABEL-$(date +%Y%m%d).log"
  local marker="$logdir/$JOB_LABEL.last-success"

  {
    echo "=== $JOB_LABEL start $(date '+%Y-%m-%dT%H:%M:%S%z') (runtime=$JOB_RUNTIME) ==="
  } >> "$datelog" 2>&1

  local code=0
  case "$JOB_RUNTIME" in
    script)
      # COMMAND is "executable [args]" resolved relative to WORKDIR.
      ( cd "$(owning_root "$JOB_DIR")/${JOB_WORKDIR:-.}" && bash -c "$JOB_COMMAND" ) >> "$datelog" 2>&1
      code=$?
      ;;
    claude)
      # COMMAND is the prompt. Launch at WORKDIR (default repo root) so the
      # relevant project skills resolve. Headless with a pre-approved tool
      # allowlist. Runs on the logged-in Claude subscription. MODEL (if set)
      # is passed through to the CLI unvalidated -- the CLI errors clearly on
      # a bad id, and a hardcoded list here would rot.
      if [[ -n "$JOB_MODEL" ]]; then
        ( cd "$(owning_root "$JOB_DIR")/${JOB_WORKDIR:-.}" && \
          claude -p "$JOB_COMMAND" --allowedTools "$AUTO_CLAUDE_ALLOWED_TOOLS" --model "$JOB_MODEL" ) >> "$datelog" 2>&1
      else
        ( cd "$(owning_root "$JOB_DIR")/${JOB_WORKDIR:-.}" && \
          claude -p "$JOB_COMMAND" --allowedTools "$AUTO_CLAUDE_ALLOWED_TOOLS" ) >> "$datelog" 2>&1
      fi
      code=$?
      ;;
  esac

  if [[ "$code" -eq 0 ]]; then
    date '+%Y-%m-%dT%H:%M:%S%z' > "$marker"
    echo "=== $JOB_LABEL ok $(cat "$marker") ===" >> "$datelog" 2>&1
  else
    echo "=== $JOB_LABEL FAILED exit $code $(date '+%Y-%m-%dT%H:%M:%S%z') ===" >> "$datelog" 2>&1
    notify_failure "$JOB_LABEL" "$code"
  fi
  return "$code"
}

# ---------------------------------------------------------------------------
# entrypoint dispatch (only when executed, not when sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    run)
      shift
      [[ $# -ge 1 ]] || { echo "usage: lib.sh run <autojob-file>" >&2; exit 2; }
      run_job "$1"
      exit $?
      ;;
    *)
      echo "lib.sh is the automations runtime/library; use install/status/uninstall." >&2
      echo "direct use: lib.sh run <abs-path-to-.autojob>" >&2
      exit 2
      ;;
  esac
fi
