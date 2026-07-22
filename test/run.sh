#!/usr/bin/env bash
# test/run.sh -- self-contained harness for the .autojob SCHEDULE renderer.
#
# Covers Feature F1 (sub-daily interval SCHEDULE): the every:<N>m / every:<N>h
# grammar, the launchd StartInterval + systemd OnUnitActiveSec renderers, the
# malformed-interval rejection, and a byte-identical golden for the unchanged
# daily HH:MM path on both backends.
#
# In-process only: it sources bin/lib.sh and calls the parser + renderers
# directly. It never installs a unit, never touches launchctl/systemctl, and
# renders BOTH backends on any OS (the renderers are platform-neutral). Run:
#
#   bash test/run.sh
#
# Exit 0 = all green; non-zero = at least one assertion failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/bin/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

# Assert $2 (a description) about whether $1 (haystack) contains $3 (needle).
has()    { case "$1" in *"$3"*) pass "$2" ;; *) fail "$2 (missing: $3)" ;; esac; }
hasnot() { case "$1" in *"$3"*) fail "$2 (unexpected: $3)" ;; *) pass "$2" ;; esac; }

# Write an .autojob with the given SCHEDULE and parse it (sets JOB_* globals).
# Echoes nothing; returns parse_job's status.
load_job() {
  local sched="$1" label="${2:-com.test.job}"
  cat > "$TMP/job.autojob" <<EOF
LABEL=$label
SCHEDULE=$sched
RUNTIME=script
COMMAND=echo hi
EOF
  parse_job "$TMP/job.autojob"
}

# ---------------------------------------------------------------------------
# 1. interval accepted + rendered on both backends (every:15m -> 900s)
# ---------------------------------------------------------------------------
if load_job "every:15m" 2>/dev/null; then
  pass "every:15m is accepted"
else
  fail "every:15m is accepted"
fi
plist="$(render_plist)"
has    "$plist" "launchd: interval emits StartInterval"        "<key>StartInterval</key>"
has    "$plist" "launchd: interval StartInterval = 900 seconds" "<integer>900</integer>"
hasnot "$plist" "launchd: interval drops StartCalendarInterval"  "StartCalendarInterval"
timer="$(render_timer)"
has    "$timer" "systemd: interval emits OnUnitActiveSec=900"   "OnUnitActiveSec=900"
has    "$timer" "systemd: interval emits OnBootSec=900"         "OnBootSec=900"
hasnot "$timer" "systemd: interval drops OnCalendar"            "OnCalendar"

# ---------------------------------------------------------------------------
# 2. hours unit (every:2h -> 7200s) on both backends
# ---------------------------------------------------------------------------
if load_job "every:2h" 2>/dev/null; then pass "every:2h is accepted"; else fail "every:2h is accepted"; fi
has "$(render_plist)" "launchd: every:2h StartInterval = 7200 seconds" "<integer>7200</integer>"
has "$(render_timer)" "systemd: every:2h OnUnitActiveSec = 7200"       "OnUnitActiveSec=7200"

# ---------------------------------------------------------------------------
# 3. malformed intervals are rejected (non-zero)
# ---------------------------------------------------------------------------
for bad in "every:" "every:15x" "every:0m" "every:m" "every:1d"; do
  if load_job "$bad" 2>/dev/null; then
    fail "malformed SCHEDULE '$bad' is rejected"
  else
    pass "malformed SCHEDULE '$bad' is rejected"
  fi
done

# ---------------------------------------------------------------------------
# 4. daily HH:MM path is byte-identical to before (golden on both backends)
# ---------------------------------------------------------------------------
# The goldens are pinned literals -- if the daily render path ever drifts, the
# diff below catches it. Machine-varying paths are filled from the same AUTO_*
# vars the renderer reads, so this is portable while still exact.
DLABEL="com.test.daily"
load_job "09:00" "$DLABEL" 2>/dev/null
DJOB="$TMP/job.autojob"
DLOG="$AUTO_LOG_BASE/$DLABEL/$DLABEL.launchd.log"

GOLD_PLIST="$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$DLABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$AUTO_LIB_DIR/lib.sh</string>
        <string>run</string>
        <string>$DJOB</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$DLOG</string>
    <key>StandardErrorPath</key>
    <string>$DLOG</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
)"

GOLD_TIMER="$(cat <<UNIT
[Unit]
Description=automations timer for $DLABEL

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
)"

# Command substitution strips trailing newlines on BOTH sides, so string
# equality is an exact byte compare of the meaningful content.
if [[ "$(render_plist)" == "$GOLD_PLIST" ]]; then
  pass "daily HH:MM launchd plist is byte-identical to golden"
else
  fail "daily HH:MM launchd plist drifted from golden"
  diff <(printf '%s\n' "$GOLD_PLIST") <(render_plist) | sed 's/^/       /' >&2
fi

if [[ "$(render_timer)" == "$GOLD_TIMER" ]]; then
  pass "daily HH:MM systemd timer is byte-identical to golden"
else
  fail "daily HH:MM systemd timer drifted from golden"
  diff <(printf '%s\n' "$GOLD_TIMER") <(render_timer) | sed 's/^/       /' >&2
fi

# ---------------------------------------------------------------------------
echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "ALL GREEN"
  exit 0
fi
echo "$FAILS assertion(s) FAILED"
exit 1
