#!/usr/bin/env bash
# bin/lib.sh -- shared core for the automations manager.
#
# Two roles:
#   1. Sourced library. install/status/uninstall/refresh/bootstrap source this
#      for the .autojob parser, plist renderer, registration + job discovery.
#   2. launchd runtime entrypoint. Rendered plists call
#      `bash lib.sh run <abs-path-to-autojob>`; that sets up logging, runs the
#      job's COMMAND, writes a last-success marker, and notifies on failure.
#
# Self-locating: AUTO_MANAGER_ROOT is derived from this file's path
# ($AUTO_MANAGER_ROOT/bin/lib.sh), never from cwd, so it works under launchd
# where cwd is undefined.
#
# Model: this repo (the MANAGER) holds only registrations + tooling. The job
# definitions (*.autojob) live in the registered SOURCE repos, in an
# automations/ dir at whatever level owns the work, discovered on disk.
#
# ASCII-only. No external state beyond ~/Library/LaunchAgents and
# ~/Library/Logs/automations.

set -uo pipefail

AUTO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # .../automations/bin
AUTO_MANAGER_ROOT="$(cd "$AUTO_LIB_DIR/.." && pwd)"               # .../automations
AUTO_REG_DIR="$AUTO_MANAGER_ROOT/registrations"
AUTO_CLAUDE_HOME="$HOME/Claude"                                   # where <NAME> checkouts live
AUTO_LOG_BASE="$HOME/Library/Logs/automations"

# launchd hands gui agents a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
# Jobs need tools that live outside that (sops, gcloud, jq, node, claude).
# Establish a known-good PATH for everything this lib runs.
AUTO_PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/share/google-cloud-sdk/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

AUTO_LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
AUTO_MANIFEST="$AUTO_LAUNCH_AGENTS/.automations-manifest"
AUTO_GUI_DOMAIN="gui/$(id -u)"

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
# is registrations/<name>.repo with NAME=<name>; the checkout is
# ~/Claude/<NAME>. Reads registrations off disk, so a gitignored (local-only)
# registration works exactly like a committed one.
registered_roots() {
  local reg name root
  for reg in "$AUTO_REG_DIR"/*.repo; do
    [[ -f "$reg" ]] || continue
    name="$(reg_field "$reg" NAME)"
    [[ -n "$name" ]] || continue
    root="$AUTO_CLAUDE_HOME/$name"
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
# plist rendering
# ---------------------------------------------------------------------------
# Render the launchd plist for the currently-parsed job to stdout.
# No RunAtLoad: jobs fire only on their StartCalendarInterval. launchd runs a
# missed slot once on next wake.
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

# ---------------------------------------------------------------------------
# runtime: execute one job (called by launchd via `lib.sh run <jobfile>`)
# ---------------------------------------------------------------------------
notify_failure() {
  local label="$1" code="$2"
  # Best-effort macOS notification; never let a notify failure mask the job's.
  osascript -e "display notification \"exited $code -- see Library/Logs/automations\" with title \"automation failed: $label\"" >/dev/null 2>&1 || true
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
