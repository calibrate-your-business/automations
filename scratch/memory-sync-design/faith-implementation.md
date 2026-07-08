# memory-sync design -- faith implementation report (2026-07-07)

Implements `scratch/memory-sync-design/findings.md` on faith. Code is owner-
approved, so it landed on **main** (local ff-merges); this note is the review
trail. Not pushed yet -- see open decisions.

## Landed on automations `main` (local, not pushed)

- `311aca8` -- **safety fix**: per-project sweep `delete=True -> delete=False`.
  memory_sync never deletes curated per-project memory. Docstring/comments
  corrected (per-project memory is first-class, backed up per host, preserved).
- `29f1e32` -- **completeness**: RESTORE guarded on `slot_is_read()` (only writes
  the slot when an effective `autoMemoryDirectory` resolves to it); per-project
  scan skips `*-worktree` encoded cwds.
- (earlier, same line of work) `e3f8151` capabilities index -> machine-local
  gitignored CAPABILITIES.md; `fa136f9` Linux systemd scheduler backend.

## brain-db (local commit, not pushed)

- `1e52ce9` -- canonical `MEMORY.md` stripped of the generated capabilities block
  down to a machine-agnostic pointer; `memory/CAPABILITIES.md` gitignored.

## Global memory on faith (decision 3) -- wired

- Confirmed CRITICAL_FACTS.md had **no** load wiring on faith (empty
  `~/.claude/CLAUDE.md`, no @import, nothing in settings).
- Added `~/.claude/CLAUDE.md` importing the brain-db canonical:
  `@~/Claude/brain-db/CRITICAL_FACTS.md`, `.../memory/MEMORY.md`, and
  `.../memory/CAPABILITIES.md` (machine-agnostic via the `~/Claude` symlink).
- Did NOT set `autoMemoryDirectory` (would orphan curated per-project memory).

## Validation (all green)

- Real-data dry run (scratch BRAIN_DB, no push): 64 per-project memories
  preserved (before == after), 64 host-scoped backups written, RESTORE skipped.
- Two-mode scratch test: per-project machine skips RESTORE + preserves memory +
  excludes worktree; Mac-mode (`autoMemoryDirectory`=slot) restores.

## Open decisions for the owner

1. **Re-arm `com.cyb.memory` on faith?** Now safe (delete=False merged). A run
   backs up per-project memory to `raw/agent-memory/faith/` and pushes it
   (host-scoped, additive); RESTORE is skipped on faith.
2. **Push automations `main` + brain-db canon to origin?** Needs coordinating
   with the Mac pulling the automations code (its old index_capabilities just
   no-ops on the pointer-only MEMORY.md -- graceful). Also: apply `delete=False`
   on the Mac (currently a harmless no-op there, but defensive).
