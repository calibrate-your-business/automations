# memory-sync + Linux-portability review -- VERDICT: GO (2026-07-07)

Reviewer: Mac-side session. Hand-verified the 4 commits (62cb3d4..217dfd0:
c1f18b3, 531fb5f, 59b243e, 217dfd0) against the diff + the design (findings.md) +
faith's report (faith-implementation.md). Owner-approved work; this is the
correctness/safety review, not a rubber-stamp.

## Verdict: GO

Code is correct (claims 1-5 all verified). The one gating prerequisite (the
brain-db gitignore) is now RESOLVED on origin: **brain-db `ee9fc25`**.

## Claims verified against the diff

1. **Never deletes per-project memory** -- CONFIRMED. Both `capture_one` calls are
   `delete=False`; no `delete=True` remains; docstring corrected.
2. **RESTORE guarded by `slot_is_read()`** -- CONFIRMED. Reads `settings.json`
   then `settings.local.json` (local overrides base); `expanduser`+`resolve`
   compare is correct; a Mac (`autoMemoryDirectory=~/.claude/memory`) resolves ->
   restores.
3. **Excludes `*-worktree` cwds** -- CONFIRMED (`project.endswith("-worktree")`).
4. **Index writes only local gitignored `CAPABILITIES.md`** -- CONFIRMED. Writes
   `CAPABILITIES.md`, never `MEMORY.md`; no commit/push; `corp_repos()` requires
   `.git` to be a DIRECTORY (excludes worktrees + non-repos).
5. **systemd backend; macOS launchd unchanged; `Persistent=true`** -- CONFIRMED
   structurally. `AUTO_OS` dispatch; darwin keeps the same
   `launchctl bootout/bootstrap/print` flow; linux uses a systemd user timer with
   `OnCalendar` + `Persistent=true`. Linux path validated by faith; macOS path
   preserved.

## Fixed during review (brain-db canon, pushed origin `ee9fc25`)

- **H1** -- added `memory/CAPABILITIES.md` to brain-db `.gitignore`. Was missing
  on origin; without it the new `index_capabilities` writes an UNTRACKED
  machine-derived file into canon that is accidentally committable (the exact leak
  the change prevents; the pre-push hook guards `scratch/`, not `memory/`).
- **M1** -- stripped the vestigial `CAPABILITIES:START/END` markers + the stale
  "pending" note in `MEMORY.md` down to a clean machine-agnostic pointer.

## COORDINATION CATCH -- act on this first

faith has a LOCAL, unpushed brain-db commit **`1e52ce9`** doing the SAME reconcile
(gitignore + MEMORY.md cleanup). It is SUPERSEDED by origin `ee9fc25`. faith must
reset/rebase brain-db to `origin/main` (drop `1e52ce9`) BEFORE pulling, or hit a
`.gitignore` + `MEMORY.md` conflict.

## Green-light sequence

1. **faith:** `git -C <brain-db> fetch origin && git -C <brain-db> reset --hard
   origin/main` (drops the dup `1e52ce9`, takes `ee9fc25`). Confirm `.gitignore`
   has `memory/CAPABILITIES.md` and `MEMORY.md` is the clean pointer.
2. **faith:** re-arm `com.cyb.memory` -- now safe. It backs up per-project memory
   to `raw/agent-memory/faith/` (delete=False), skips RESTORE (per-project
   machine), writes the local gitignored `CAPABILITIES.md`.
3. **Mac:** pull the automations code (4 commits) + brain-db; its memory job then
   runs `delete=False` + the new index (local gitignored `CAPABILITIES.md`, no
   canon pollution).

## Optional hardening (LOW, non-blocking)

- **L1:** `slot_is_read()` should also require `autoMemoryEnabled != false` (a
  dir-set-but-disabled machine would restore into an unread slot).
- **L2:** the faith `@import` of `CAPABILITIES.md` is empty until the first
  memory-job run generates it -- self-heals; not a bug.

## Status

`com.cyb.memory` is SAFE to run once each machine is on `origin/main` for BOTH
automations and brain-db. Only remaining blocker: faith dropping its duplicate
local brain-db commit (`1e52ce9`).
