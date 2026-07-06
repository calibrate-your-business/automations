# session-learnings pass -- reusable prompt (agent-ops automation)

The GENERATOR over captured session raw. It proposes operating knowledge and
CLAUDE.md edits; it does NOT hand anything to the owner and does NOT edit any
CLAUDE.md. Vetting + owner review is the separate `review-recommendations` skill.

Run standalone (`claude -p "$(cat agent-ops/session-learnings.prompt.md)"` from
the automations repo) or via the session-learnings.autojob. This is strategy;
`agent-ops/capture_sessions.py` is the mechanics that produce the raw.

---

You distill durable OPERATING knowledge from Claude Code session transcripts so
future sessions and the loops critics stop repeating mistakes. Data store is
`$BRAIN_DB` (default `~/Claude/brain-db`).

## Input + delta

Read session raw under `$BRAIN_DB/raw/sessions/<host>/*.md` -- one flattened
session each. Frontmatter carries `session_id`, `project`, `cwd`, `date`.
Process only sessions NEW or CHANGED since the last pass, tracked by
`$BRAIN_DB/raw/sessions/.last-learnings.json`
(`{ "processed": { "<session_id>": "<date>" } }`). If nothing is new, stop.
Update the marker at the end.

## GROUND every recommendation in the session's own repo (required)

A recommendation is only sane if it is true of the repo the session ran in. For
each session, the `cwd` frontmatter is that repo's absolute path. Before
proposing anything for a session:
- Resolve the repo: the nearest ancestor of `cwd` containing `.git` (a
  `-worktree` dir belongs to its primary repo).
- READ that repo's reality: its `CLAUDE.md` (root and the relevant subproject),
  `.claude/skills/`, and the files the rule would touch. Recent git state over
  any doc's claim.
- A rule is scoped to where it is TRUE. Do NOT generalize one repo's convention
  to "all repos" -- verify per repo; workflows differ (e.g. a worktree
  convention may be fact in one repo and false everywhere else).

## Angles (mine each session)

Angle 0 is the pre-filter -- find the loud moments first, then widen.

0. **Corrections (all-caps / frustration).** Every user turn in ALL-CAPS, with
   profanity, or "why are you / STOP / no / that's wrong / I've said this N
   times". Each = the agent missed something obvious. What was missed, why
   obvious, the rule.
1. **Arch-decisions.** Durable rulings ("X is the source of truth", ownership,
   topology, a deploy pointer, a naming convention).
2. **Process-omission.** Skipped an established process: no plan, loops harness
   unused, no critic, a required skill not invoked.
3. **Skill-signals.** A skill that should have been used but wasn't; recurring
   manual work that should BE a skill; a stale/wrong skill.
4. **Re-litigation.** Re-derived or re-opened a settled decision -> a missing
   canon doc.
5. **Tool-reinvention.** Rebuilt a helper/tool/pattern that already exists.

Each finding: `{ angle, session_id, project, cwd, what_happened (1-2 sentences,
ABSTRACTED -- no secrets/PII/customer names), evidence (short scrubbed quote),
rule (imperative, reusable), target (the EXACT existing file the rule belongs
in -- see next), scope, severity 1-5 (corrections floor at 3), recurrence_key }`.

## Targets must already exist (hard rule)

`target` must be a CLAUDE.md (or skill file) that ALREADY EXISTS in the repo
where the rule was verified true. NEVER invent a target:
- Do not propose a new `~/.claude/CLAUDE.md`, a home/global config, or any new
  canonical file as a default. If a rule is genuinely cross-repo and has no
  existing home, emit it under a clearly-marked "NEEDS A HOME (owner decision)"
  section -- a proposal for the owner to place, never an assumed target.
- If the repo has no CLAUDE.md at all, say so; creating one is an owner decision.

## Synthesize + write (to `$BRAIN_DB`)

- Dedup by `recurrence_key` across sessions; a rule in K sessions outranks a
  one-off (raise severity, note the count). Resolve contradictions by
  later-ruling-wins; record the resolution, not the flip-flop.
- `wiki/concepts/operating-rules.md` -- REWRITE (integrate, don't stack dupes);
  group by target repo; each rule gets a one-line rationale + `[[provenance]]`.
- `wiki/concepts/agent-anti-patterns.md` -- the recurring failure modes.
- `reports/claude-md/<date>.md` -- the digest for `review-recommendations`:
  grouped by target repo, each item `{ rule, rationale, exact target file,
  proposed text, source sessions }`, plus the "NEEDS A HOME" section. RECOMMEND
  ONLY -- edit no CLAUDE.md.
- Rebuild the index: `BRAIN_DB=$BRAIN_DB python3 ~/Claude/brain/db/build_index.py`.
- Commit + push brain-db non-interactively, only if there is a delta.

## Rules of the pass

- Report-only for CLAUDE.md; never edit one.
- Privacy: rules are abstracted; never copy a secret, credential, or customer
  name into the wiki or digest.
- High-signal, not a log. Unsure if it's durable? Leave it out.
- Cite provenance on every rule.

## Self-test (fixture)

Session `raw/sessions/<host>/*__3541de34-*.md` (built the automations manager)
MUST yield at least: automations runs jobs and is NOT a deployer (never touches
prod); brain-db is the single corporate KB (don't fragment it); no interim
restoration; validate a job for the current architecture before migrating it;
don't reinvent an existing layer; land reversible git work without asking; and
-- the meta-rule -- the owner's feedback is a design input to be turned into a
PROPOSAL, never executed directly. If the pass can't recover those, it isn't
working.
