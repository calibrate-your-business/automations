#!/bin/bash
# Daily recommendations-review alarm. A CLAUDE.md digest in
# $BRAIN_DB/reports/claude-md/*.md is OUTSTANDING until a human dispositions it
# and moves it into reviewed/. While any are outstanding, fire a macOS alert
# pointing at the automations-management session. Exit 0 either way -- this is
# an alarm, not a failure.
set -uo pipefail
BRAIN_DB="${BRAIN_DB:-$HOME/Claude/brain-db}"
DIR="$BRAIN_DB/reports/claude-md"
mkdir -p "$DIR/reviewed"
count=$(find "$DIR" -maxdepth 1 -name '*.md' ! -name 'README.md' | wc -l | tr -d ' ')
if [ "$count" -gt 0 ]; then
  names=$(find "$DIR" -maxdepth 1 -name '*.md' ! -name 'README.md' -exec basename {} \; | sort | paste -sd', ' -)
  echo "OUTSTANDING recommendations: $count ($names)"
  osascript -e "display notification \"$count CLAUDE.md digest(s) awaiting review: $names -- open the automations-management session\" with title \"recommendations review\" sound name \"Glass\"" || true
else
  echo "no outstanding recommendations"
fi
exit 0
