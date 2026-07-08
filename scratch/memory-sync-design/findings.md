# memory_sync.py: global vs project memory -- design decision (2026-07-07)

Source: Mac-side investigation for the faith memory-job problem. Owner-directed
decision. FOR the faith automations agent to implement. Do not treat as canon --
this is scratch (for review + action), not brain-db.

## Problem

`memory_sync.py` sweeps `~/.claude/projects/*/memory/*.md` with `delete=True`,
assuming per-project dirs are disposable CLI drift. That is now FALSE: per-project
memory is first-class, human-curated (real frontmatter, a curated `MEMORY.md`
index; ~60 entries for cyb on faith). Running the job on faith DELETES curated
memory. Root cause: the two machines are configured differently and the sweep was
written for the Mac's model only.

## Ground truth (verified on the Mac 2026-07-07)

- **Mac:** `autoMemoryDirectory=~/.claude/memory`, `autoMemoryEnabled=true` -> one
  global slot, NO per-project scoping; `~/.claude/projects/*/memory` is EMPTY, so
  the sweep is a harmless no-op. Global operating memory loads from the slot
  (restored from brain-db).
- **faith:** `autoMemoryDirectory` NOT set -> per-project memory is ACTIVE and
  curated -> the sweep DELETES it. Global memory (`MEMORY.md`) does NOT load
  (nothing reads `~/.claude/memory` there).
- `CRITICAL_FACTS.md` reaches agents (appears in transcripts) but its load wiring
  is UNCONFIRMED -- not found in `settings.json`, hooks, or an `@import` in the
  global `MEMORY.md`. Confirm this before wiring faith's global memory.

## Decisions

1. **Global vs project -- route by LOCATION.**
   - GLOBAL (machine-agnostic): canonical `MEMORY.md` + `CRITICAL_FACTS.md`; lives
     in brain-db; delivered everywhere.
   - PROJECT (per-project curated; `metadata.type` user|feedback|project|reference):
     scoped to one project; NEVER delete.
   - Router = LOCATION (global slot vs `projects/*/memory`), NOT `metadata.type`
     (that is a within-store taxonomy of fact KIND, not a storage router; a
     "feedback" fact can be global or project-scoped).

2. **Project memory stays MACHINE-LOCAL** (per-host backup, not cross-synced).
   The machines have different roles (Mac = marketing, faith = coding), so
   per-project work is largely machine-specific; machine-derived stays local (same
   principle as the capabilities-index fix). Backup = capture to
   `brain-db/raw/agent-memory/<host>/` with delete OFF. Cross-machine per-project
   sync is a future opt-in, not now.

3. **Global memory on faith -- deliver by IMPORT; do NOT set `autoMemoryDirectory`
   there.** Setting it redirects all memory to one dir and orphans/mixes faith's
   curated per-project memory. Instead deliver global operating memory via a
   machine-agnostic `@`-import of the brain-db canonical (`CRITICAL_FACTS.md` +
   `MEMORY.md`) from a CLAUDE.md that loads on every machine -- coexists with
   per-project memory. PREREQ: confirm the current `CRITICAL_FACTS.md` load path;
   if it is already such an import, extend it to `MEMORY.md`; if not, add it.

## The `memory_sync.py` change

- **CRITICAL (ship now):** the per-project sweep must stop deleting. Line ~93:
  `capture_one(mf, project, delete=True)` -> `delete=False`. This alone makes the
  job non-destructive on both machines (no-op on the Mac, safe backup on faith).
- **Docstring/comment:** replace the "per-project dirs are CLI drift that should
  stop appearing / are swept" language with: per-project memory is first-class,
  human-curated; captured to `raw/agent-memory/<host>/` as a per-host backup and
  LEFT IN PLACE.
- **Guard RESTORE:** only copy canonical `MEMORY.md` into `AUTO_MEMORY_DIR` when
  the machine actually reads it (`autoMemoryDirectory` resolves to that dir). On a
  per-project machine it writes a dir nothing reads (misleading); global memory
  there arrives via the import (decision 3), not this restore.
- **Exclude worktrees:** skip `*-worktree` encoded cwds in the project scan so a
  transient worktree session is not captured as a phantom project.

## Status

Owner-approved decision. Implement the `delete=False` safety fix first; the
restore-guard + the CRITICAL_FACTS/MEMORY import are the completeness items.
