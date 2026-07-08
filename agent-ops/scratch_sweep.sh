#!/usr/bin/env bash
# agent-ops: scratch-sweep -- a once-a-day nudge listing open WIP across repos.
#
# WIP lives on each repo's `scratch` branch (`scratch/WIP.md`, per the scratch +
# review discipline). This reads those registries and notifies with review
# pointers, so a multi-repo, multi-agent owner does not have to hold the open list
# in their head.
#
# ONE MACHINE by design: it host-guards to macOS (the attended machine) so it never
# double-fires across devices. Machine AFFINITY (a HOST field to target Mac vs
# Linux per job) is future work in the scheduler backend. Notifier is osascript
# today; swap to a phone push (Telegram) later to make it fully machine-independent.
set -uo pipefail
[ "$(uname)" = "Darwin" ] || exit 0                 # runs on the Mac only
export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"

# parent dir of the manager repo -- sibling repos live alongside
ROOT="${AUTO_SCRATCH_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LOG="$HOME/Library/Logs/automations/scratch-sweep.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== scratch-sweep $(date '+%Y-%m-%dT%H:%M:%S%z') ==="

blob_url() {   # git origin remote -> GitHub blob URL for the scratch WIP.md
  local url; url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  url="${url%.git}"; url="${url/git@github.com:/https://github.com/}"
  echo "$url/blob/scratch/scratch/WIP.md"
}

total=0; repos=0; summary=""
for d in "$ROOT"/*/; do
  [ -d "${d}.git" ] || continue
  name=$(basename "$d")
  git -C "$d" ls-remote --exit-code --heads origin scratch >/dev/null 2>&1 || continue
  git -C "$d" fetch origin scratch --quiet 2>/dev/null || true
  wip=$(git -C "$d" show origin/scratch:scratch/WIP.md 2>/dev/null) || continue
  n=$(printf '%s\n' "$wip" | grep -cE '^\| scratch/')   # item rows reference scratch/ paths
  [ "${n:-0}" -gt 0 ] || continue
  repos=$((repos + 1)); total=$((total + n))
  echo "  $name: $n open -> $(blob_url "$d")"
  summary="$summary ${name}(${n})"
done
echo "TOTAL: $total item(s) across $repos repo(s)"

if [ "$total" -gt 0 ]; then
  osascript -e "display notification \"$total item(s) to review:${summary}. Links in the log + each scratch branch's WIP.md.\" with title \"scratch-sweep: parked work awaiting you\"" 2>/dev/null || true
fi
echo "=== done ==="
