---
name: review-recommendations
description: Vet and disposition a session-learnings digest (brain-db reports/claude-md/) with the owner, one item at a time. Use when the owner asks to review recommendations / the digest, or the recommendations-review alarm fires. Every item is verified by subagents against the reality of the repo the session ran in, plus an adversarial critic, BEFORE it reaches the owner -- never hand the owner an unvetted recommendation.
---

# review-recommendations

The session-learnings pass is a GENERATOR: it extrapolates. It can generalize
one repo's rule to all repos, invent placement targets that do not exist, or
cite mechanisms nobody built. This skill is the VERIFIER. The owner arbitrates
genuine judgment calls only; everything mechanical is vetted before they see it.

## Protocol with the owner (hard rule #1)

The owner's words are DESIGN INPUT, not work orders.
**Feedback -> you make a PROPOSAL -> the owner approves -> you execute.**
Never collapse this into feedback->execute, and never into feedback->paralysis.
- One item at a time. Present a single vetted item, wait for the verdict, apply
  exactly that, move on. Never batch, never run ahead.
- A question from the owner is a question, not an approval. Answer it,
  re-present, wait.
- Nothing is applied without an explicit yes on BOTH text and placement.
  "Approved, but..." means the caveat is unresolved -- resolve it first.
- After a correction: STOP. No further tool calls until you have explained the
  state and the owner directs. Then do not over-rotate into permission-seeking
  -- land approved work; reserve confirmation for irreversible actions.

## Per-item pipeline (BEFORE the owner sees the item)

Batch the subagent work up front if the digest is large, but present strictly
one at a time.

1. **Ground-truth in the SESSION'S OWN REPO (subagent, read-only).** Each digest
   item cites the session's `cwd`/`project`. Resolve the repo (nearest `.git`
   ancestor of `cwd`; a `-worktree` maps to its primary repo) and dip into it:
   - Does the proposed TARGET file exist in that repo? A missing target is a red
     flag, never something to silently create.
   - Is the rule TRUE of that repo -- checked against its CLAUDE.md, skills, and
     the actual files/recent git state? If it claims a scope wider than that
     repo, verify each scope; scope the rule down to where it is true.
   - Does every mechanism/tool/path it names exist?
   - Does it duplicate or contradict what the target already says? Cite file:line.
2. **Adversarial critic (subagent, separate context).** Told: "this
   recommendation is wrong -- prove it." Attack: over-generalization from one
   session/context; invented targets; stale provenance (superseded later); wrong
   placement (belongs in another repo, a skill, or a tool guard, not prose);
   rule-vs-noise (a one-off preference dressed as canon).
3. **Verdict**: APPLY-AS-IS / AMEND (corrected text + placement + why) / REJECT
   (why), with the evidence attached.

## Presenting

Per item, tightly: vetted rule text, verified target file, verdict + one-line
evidence, and the open judgment call if any. Then STOP and wait.
- If verifier and critic disagree, say so -- that IS the judgment call.
- On yes: edit exactly the approved target, honoring that repo's workflow (e.g.
  cyb edits go through a `<project>-worktree` branch + ff-merge; direct-to-main
  repos commit directly). Batch commits per repo at the end.

## Closing

1. Every item dispositioned: applied / amended+applied / rejected (note why).
2. Skill/system maintenance flags become follow-up items -- list them, never
   silently drop.
3. Move the digest into `reports/claude-md/reviewed/` (silences the
   recommendations-review alarm) and commit the data repo.
4. Feed systematic generator errors (e.g. invented global targets) back into
   `agent-ops/session-learnings.prompt.md` so the generator stops producing that
   class of garbage.

## Hard rules

- Never invent a placement target. A rule's home is a file that already exists
  in the repo where the rule is true. A NEW canonical file (or any global/home
  config) is an owner decision to propose explicitly, never a default.
- Never edit anything while presenting. Present -> verdict -> apply.
- Provenance keys (session ids, K counts) are claims, not proof -- the
  ground-truth pass against the real repo is what makes an item trustworthy.
