# morning-review spec

## Intent
Ship a durable, headless `com.cyb.morning-review` automation that runs every morning at 05:47, reviews the health of the whole overnight fleet, and writes a dated report to `~/Documents/automations-morning-report/` for the owner to read over coffee. Headline job: monitor the just-landed launchd fix (ProcessType Background->Interactive, `bin/lib.sh:277`, deployed to all 10 plists) that should stop macOS throttling display-off overnight runs -- the fix is unproven until the first post-fix night, and yesterday's 3h24m leadgen freeze is the failure mode it must catch. The headline metric is per-job DURATION (ok timestamp minus start timestamp from the dated log), not marker recency, so a regression is unmissable even if the reviewer itself runs late or the job has since recovered. Replaces the fragile session-only cron -- CronCreate session-cron job `60aeb82f` (a session-bound reminder created earlier this session, NOT a git ref) -- which dies when its Claude session exits. Done = report appears every morning regardless of any chat session/restart/context-clear, a desktop notification carries the one-line verdict, and the session cron is deleted.

## Constraints
- Durability is the point: a launchd unit installed by `bin/install`, discovered as a committed `.autojob`, zero dependence on any live Claude session. Inherits ProcessType=Interactive from the plist template (`bin/lib.sh:277`).
- Self-monitoring caveat: the reviewer runs at 05:47, inside the display-off throttle window, and depends on the very Interactive fix it monitors. Mitigations: the report's first line prints its own generation time vs scheduled time (a late reviewer is itself a throttle signal), and the duration metric keeps a late reviewer from masking a job regression.
- Read-only is PROMPT DISCIPLINE, not enforcement: the tool allowlist is a single global constant (`AUTO_CLAUDE_ALLOWED_TOOLS="Read Edit Write Bash Glob Grep"`, `bin/lib.sh:70`) granting Write/Edit/Bash to every claude job; there is no per-job lockdown. The prompt therefore carries explicit prohibitions: write nothing except the one report file; no git; no launchctl/install/uninstall/kickstart; never touch `~/Claude/brain-db` (canon: `brain-db/memory/MEMORY.md` holds only owner-approved content).
- Nothing hardcoded about the fleet: roster, schedules, health, and last-success all come from `bin/status` and the per-job dated logs at runtime. Schedules churn (x-bookmarks moved 08:10 -> 03:10); a hardcoded list goes stale silently.
- Delivery: `run_job` posts a desktop notification only on FAILURE (`bin/lib.sh:542-544`), so a successful report would sit unseen in a log. The job therefore both writes the report file AND fires a one-line osascript notification with the verdict (matching the scratch-sweep morning-nudge precedent).
- Provenance discipline: the prompt states the run's identity (it IS the `com.cyb.morning-review` job); the report opens with that line; the leadgen report's hallucinated "Run by" header is ignored.
- automations is not a deployer. ASCII-clean; use Bash for all shell.

## Spec

### File and registration
`.autojob` at `automations/morning-review.autojob` in the automations repo itself (agent-ops family -- this is a global fleet-health job, so the automations repo owns it). Discovery is `**/automations/*.autojob` under registered roots (`bin/lib.sh:209-222`).

Fields:
- `LABEL=com.cyb.morning-review`
- `SCHEDULE=05:47` -- healthy leadgen (05:15 start) finishes 05:22-05:27, leaving ~20 min buffer. Jobs scheduled after 05:47 are covered on a one-day lag (see prompt); the report states this boundary.
- `RUNTIME=claude`
- `MODEL=claude-sonnet-5` -- default, but explicitly flagged as an owner decision (Open items).
- `WORKDIR=.`

### Data sources (all runtime-discovered, none hardcoded)
- Roster/schedules/health/last-success: `bin/status` (which reads the `<LABEL>.last-success` marker written only on exit 0 at `bin/lib.sh:509,540`; `bin/status:36-37`). Do NOT enumerate `~/Library/Logs/automations/` directories -- the retired `com.cyb.memory-sweep` leaves a ghost dir that would create false entries.
- Per-job timing: dated log `~/Library/Logs/automations/<LABEL>/<LABEL>-YYYYMMDD.log`, sentinels `=== <LABEL> start <ISO> ===` (lib.sh:512), `=== <LABEL> ok <ts> ===` (:541), `=== <LABEL> FAILED exit N <ts> ===` (:543). Both timestamps are offset-stamped ISO-8601, same day, so duration is a straight subtraction.
- x-bookmarks internals: `pull-and-process.sh` emits `pull_rc=` (:56) and `merged new bookmarks:` (:40).

### Per-job classification (the core logic)
For each roster job, keyed to ITS OWN schedule relative to the review time:
- Scheduled BEFORE 05:47 -> read today's dated log, expect today's success.
- Scheduled AFTER 05:47 (e.g. 06:00 recommendations-review, 06:00 skills-sync, 08:00 scratch-sweep) -> read yesterday's log, evaluate that run, and report "next fire HH:MM today" -- never a false failure.

Four states from the dated log:
1. No start line -> DID-NOT-START (launchd missed the fire).
2. Start line, no ok/FAILED -> STILL-RUNNING-OR-FROZEN; report minutes elapsed vs baseline.
3. FAILED line -> FAILED-FAST, with exit code.
4. ok line -> compute DURATION = ok - start. Duration > ~3x baseline (e.g. >30 min for leadgen) -> THROTTLE-SUSPECT even though it succeeded. This replaces marker recency as the throttle test: yesterday's 3h24m freeze stays visible even if leadgen has since recovered.

Baselines: leadgen 7-12 min, session-learnings 8-19 min, brain-ingest <1 min; jobs without a stated baseline are flagged only when wildly above their own recent norm.

Headline verdict: fix HELD (all pre-05:47 jobs ok within ~3x baseline) vs REGRESSED.

x-bookmarks semantics: report BOTH the final `pull_rc=` value AND the merged count. `pull_rc!=0` means the X browser instance was likely not open at 03:10 but the brain-export half still ran; `merged new bookmarks: 0` with exit 0 is healthy-idle, not a failure.

### COMMAND (single line in the file; shown wrapped here)
```
COMMAND=You are the com.cyb.morning-review launchd automation, scheduled 05:47;
that is your only identity -- state it, never invent another. Deliverable: ONE
file, ~/Documents/automations-morning-report/YYYY-MM-DD.md for today's local
date (mkdir -p the directory first). Report line 1: 'com.cyb.morning-review --
generated at HH:MM:SS (scheduled 05:47)' using actual current local time; a
late generation time is itself a throttle signal, so never fake it. Line 2:
'Coverage: jobs scheduled before 05:47 evaluated on today's run; jobs scheduled
after 05:47 evaluated on yesterday's run with next fire time noted.' STEP 1
DISCOVER: run cd ~/Claude/automations && bin/status and take the FULL job
roster, each job's SCHEDULE, scheduler/health state, and last-success from that
output ONLY; do not enumerate ~/Library/Logs/automations/ to find jobs (retired
jobs leave ghost dirs there). Evaluate EVERY roster job; hardcode nothing. STEP
2 CLASSIFY each job from its dated log ~/Library/Logs/automations/<LABEL>/
<LABEL>-YYYYMMDD.log (today's log if scheduled before now, else yesterday's,
marking 'next fire HH:MM today' -- never call a not-yet-due job failed). Use
the sentinels '=== <LABEL> start <ts> ===', '=== <LABEL> ok <ts> ===', '===
<LABEL> FAILED exit N <ts> ===': no start line = DID-NOT-START (launchd missed);
start but no ok/FAILED = STILL-RUNNING-OR-FROZEN (report minutes elapsed vs
baseline); FAILED = FAILED-FAST with exit code; ok = compute DURATION = ok
timestamp minus start timestamp, and if duration exceeds ~3x baseline mark
THROTTLE-SUSPECT even though it succeeded. Baselines: leadgen 7-12 min,
session-learnings 8-19 min, brain-ingest under 1 min; other jobs flag only if
wildly above their own recent norm. Headline verdict: ProcessType Interactive
fix HELD (all pre-05:47 jobs ok within ~3x baseline) or REGRESSED. STEP 3
X-BOOKMARKS: from its log report BOTH the final pull_rc= value AND the 'merged
new bookmarks:' count; pull_rc nonzero means the X browser instance was likely
not open at run time but the brain-export half still ran; merged 0 with exit 0
is healthy-idle, not a failure. STEP 4 LEADGEN CONTENT: from the newest report
in sw-leadgen-archive extract the ads TL;DR and any P0 items; IGNORE that
report's 'Run by' header, it is hallucinated provenance. STEP 5 WRITE the
report: header lines, then a duration table covering every roster job (label,
schedule, state, duration, baseline, verdict), then failures and anomalies,
then the x-bookmarks line, then ads TL;DR and P0s, then a one-line overall
verdict. STEP 6 NOTIFY: run osascript -e 'display notification "<one-line
verdict>" with title "morning-review"' -- e.g. 'fix HELD, all clear' or '2
issues -- see report'. HARD LIMITS: this is a read-only review; write NOTHING
except the single report file; no git commands; no launchctl, install,
uninstall, or kickstart; never read from or write to ~/Claude/brain-db; take no
corrective actions, only report. ASCII only throughout.
```

### Report shape
1. Identity + generation-time line; coverage-boundary line.
2. Duration table (every roster job).
3. Failures/anomalies detail (exit codes, elapsed-vs-baseline for frozen jobs).
4. x-bookmarks pull_rc + merged count.
5. Ads TL;DR + P0 from newest sw-leadgen-archive report.
6. One-line overall verdict (mirrors the notification text).

## Migration phases
1. **Land**: commit `automations/morning-review.autojob` to automations `main`.
2. **Deploy**: ff-pull the primary checkout, run `bin/install`; verify `launchctl print` shows the label loaded with ProcessType Interactive and next fire 05:47.
3. **Smoke**: kickstart one manual run; confirm the dated report file appears with correct identity/coverage header, the duration table covers the full roster from `bin/status` (no ghost memory-sweep entry), and the desktop notification fires.
4. **First morning**: after the first display-off overnight, read the 05:47 report; confirm the generation-time line is on time and the leadgen duration verdict matches reality against the raw logs.
5. **Retire the stopgap**: delete CronCreate session-cron job `60aeb82f` (the session-bound 7:54 AM reminder -- not a git ref) once the durable job has produced at least one good morning report.

## Open items
- **MODEL (owner decision)**: default is `claude-sonnet-5` (cheap, sufficient for log-reading), but fleet convention is `claude-opus-4-8` -- all 3 other claude jobs use it, and central model-sweeps target those files, so a divergent ID could be missed by a sweep. Both options presented; do not silently diverge.
- **Time**: 05:47 assumed final (20 min buffer after healthy leadgen); confirm, or move later to tighten the one-day lag on post-05:47 jobs.
- **Delivery**: file + notification shipped; in-channel delivery (e.g. into a chat surface, the eventual Platform-v9 notification path) remains open.
- **Machine-readable status line**: append a single grep-able `STATUS: HELD|REGRESSED|MIXED` line at the end of each report for future tooling?
- **Reviewer blind spot**: if the reviewer itself is throttled or never fires, nothing reports that. The generation-time line and duration metric mitigate a late run, but a fully missing run needs the owner to notice a missing notification; a dumb non-claude watchdog is a possible follow-up.
- **Baseline drift**: baselines are literals in the prompt; revisit once a few weeks of duration data exist.
