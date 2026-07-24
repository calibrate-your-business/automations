# WIP registry (automations scratch branch -- NOT for main)

Parked / in-progress automations work, committed here and pushed for review on
GitHub. This branch NEVER merges to main (guarded). Swept every morning by
com.cyb.scratch-sweep.

| item | status | created | next action |
|---|---|---|---|
| scratch/memory-sync-design/findings.md | IMPLEMENTED on faith (main) | 2026-07-07 | see faith-implementation.md |
| scratch/memory-sync-design/faith-implementation.md | done + validated | 2026-07-07 | superseded by the review below |
| scratch/memory-sync-design/review-verdict.md | GO; faith DONE (brain-db reset->ee9fc25; com.cyb.memory armed+ran, 64 memories preserved; L1 hardening c3720db) | 2026-07-07 | Mac only: pull automations (through c3720db) + brain-db on its schedule (runs same delete=False) |
| scratch/plans/morning-review/morning-review-spec.md | PENDING OWNER REVIEW | 2026-07-24 | generator->critic->revise loop complete; owner reviews in the morning w/ the throttle-fix result, then approve/adjust -> implement the .autojob |
