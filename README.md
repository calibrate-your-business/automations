# automations

A small launchd job manager for macOS. Job definitions are `*.autojob` files
that live in the repos they serve; this repo holds only the tooling that
discovers, schedules, and monitors them. That split is the point: the manager
can be public while every job stays private to its own repo.

You need macOS and git. The `claude` CLI ([Claude Code](https://claude.com/claude-code))
is only required if you want jobs that run headless Claude sessions
(`RUNTIME=claude`).

## Quickstart

The fastest path is to let Claude Code do the setup:

```sh
git clone https://github.com/calibrate-your-business/automations.git
cd automations
claude
```

and prompt:

> Read the README and set up my project.

Claude will follow the next section. Setting up by hand? The same steps work
read as instructions to you.

## Setup (for Claude)

Execute these steps in order. Each one is checkable before moving on.

1. **Verify prerequisites.**
   - `uname` prints `Darwin`. This manager drives launchd; it is macOS-only
     (see `FUTURE-WORK.md` for the portability roadmap).
   - `git --version` succeeds.
   - Ask the user whether they want scheduled headless Claude jobs
     (`RUNTIME=claude`). If yes, `command -v claude` must succeed; if it does
     not, stop and have them install and log in to Claude Code first.

2. **Confirm the directory layout.** Source repos are discovered as siblings
   of this checkout: `<parent-dir>/<NAME>`. Ask the user where their repos
   live. If this repo is not already checked out next to them, re-clone it
   there before continuing -- launchd runs jobs from baked absolute paths, so
   the sibling layout is what makes everything resolve.

3. **Register their first repo.** Ask which repo should get the first job
   (any sibling git checkout works). Create `registrations/<name>.repo`:

   ```
   NAME=<name>
   BRANCH=main
   ```

   Tell the user this file is gitignored on purpose -- see "Privacy model"
   below.

4. **Create a starter job in THEIR repo** (not this one), at
   `<their-repo>/automations/heartbeat.autojob`:

   ```
   LABEL=com.<name>.heartbeat
   SCHEDULE=09:00
   RUNTIME=script
   COMMAND=echo "heartbeat ok: $(date)"
   ```

   If they want to watch it fire, set SCHEDULE a few minutes ahead of now.

5. **Install and verify.** Run `bin/install`, then `bin/status`. The job's
   LABEL must show LAUNCHD `loaded` and HEALTH `ok`.

6. **Optionally trigger a run now:**

   ```sh
   launchctl kickstart -k gui/$(id -u)/com.<name>.heartbeat
   ```

   Then check the log under `~/Library/Logs/automations/<LABEL>/` and confirm
   `bin/status` shows a LAST-SUCCESS timestamp.

7. **Explain the day-to-day loop:** edit or add `.autojob` files in the source
   repos, merge to their main branch, then `bin/refresh && bin/install` here.
   `bin/status` is the single pane of glass.

## How it works

- **Manager (this repo)** = `bin/` tooling + `registrations/`. Nothing here
  reveals a job's schedule, command, or purpose.
- **Jobs** = `*.autojob` files in the source repos, in an `automations/`
  directory at whatever level owns the work (repo root for a single product,
  deeper for a subproject-scoped job). Discovered on disk as
  `**/automations/*.autojob`.
- **Registration** = `registrations/<name>.repo` (`NAME` + optional `BRANCH`).
  It only names a source repo; the manager reads the sibling checkout
  `<parent-dir>/<NAME>` for that repo's jobs.
- **Runtime** = `bin/lib.sh run <file>`, called by launchd at the scheduled
  time. It sets a known-good PATH, runs the job as a shell script or a
  headless `claude -p` with a bounded tool allowlist (`Read Edit Write Bash
  Glob Grep`, plus `--model` when the job pins one), logs to
  `~/Library/Logs/automations/<LABEL>/`, and posts a macOS notification on
  failure.

## The .autojob format

`KEY=value`, one per line; `#` comments allowed; the first `=` splits, so
values may contain `=`.

```
LABEL=com.example.my-job   # launchd label, unique across all jobs
SCHEDULE=09:00             # HH:MM daily
RUNTIME=script             # or: claude
COMMAND=./do-thing.sh      # script: exe+args run at WORKDIR; claude: the prompt
WORKDIR=some/path          # optional; relative to the owning repo root; default .
MODEL=claude-sonnet-5      # optional; claude runtime only -- passed to
                           # `claude --model`; absent = the CLI's default model
ENABLED=true               # optional; false = committed but not scheduled
```

## Commands

| Command | What it does |
|---|---|
| `bin/install [all]` | discover `*.autojob`, render + reconcile launchd plists |
| `bin/install <path>` | install one `.autojob` |
| `bin/uninstall <label\|all>` | remove from launchd |
| `bin/status` | schedule / launchd / health / last-success table |
| `bin/refresh` | ff-pull each registered checkout to pick up merged jobs |
| `bin/bootstrap` | fresh machine: clone sources, verify prereqs, install |

## Privacy model

- **Registrations are local-only by default.** `registrations/*.repo` is
  gitignored; a registration on disk works fully but is invisible to anyone
  who clones this repo. `git add -f registrations/<name>.repo` publishes that
  repo's participation -- only its logical name, never its jobs.
- **Job bodies never enter this repo.** Schedules, commands, and prompts live
  in the source repos, under whatever visibility those repos have.
- **Remote URLs stay out of git** in the gitignored `origins.local`
  (`NAME=<git-remote-url>` lines, used by `bin/bootstrap` to clone).

## Agent-ops (built-in global automations)

Beyond scheduling other repos' jobs, this repo ships a few machine-global
automations of its own -- they operate on the AGENT, not any one project.
Their code lives in `agent-ops/`; their `*.autojob` files in `automations/`.
They write DATA to a store you configure (`BRAIN_DB`, default `~/Claude/brain-db`),
never into this repo.

- **`com.cyb.session-capture`** -- flattens this machine's Claude Code session
  transcripts into immutable raw markdown (delta-driven, secret-scrubbed). Each
  record keeps the session's working directory so downstream analysis can ground
  itself in the repo the session ran in.
- **`com.cyb.session-learnings`** -- a headless `claude` pass that distills
  operating rules + an anti-patterns page from the captured sessions, and emits
  a report-only digest of recommended CLAUDE.md edits. It never edits a
  CLAUDE.md; the [`review-recommendations`](.claude/skills/review-recommendations)
  skill vets the digest with the owner, one item at a time.
- **`com.cyb.recommendations-review`** -- alerts while a digest sits
  un-dispositioned.
- **`com.cyb.memory`** -- bidirectional Claude Code memory sync. Claude Code
  writes auto-memory on its own; this job CAPTURES it into the store nightly and
  RESTORES a curated canonical `MEMORY.md` (kept in the store, not here) into the
  slot Claude reads at session start. Point Claude at one shared memory dir with
  `"autoMemoryDirectory": "~/.claude/memory"` in `~/.claude/settings.json` so a
  single curated file serves every project.
- **`com.cyb.skills-sync`** -- keeps the user-level skill library
  (`~/.claude/skills/`) current from a shared skills repo, so every session in
  every project sees the same skills. This is the worked example of the whole
  automations pattern: the job and its tooling are public and generic, while
  the private source repo URL lives only in the gitignored `origins.local`
  (env `SKILLS_REPO_URL` also works). Pruning is manifest-guarded -- the sync
  only ever removes skills it installed, never a hand-placed one.

These are a template as much as a feature: fork them, or write your own
`agent-ops/` automations, and point `BRAIN_DB` wherever you keep your data.

## Works well with

This manager is standalone -- it schedules jobs for any repo. It also pairs
with its sibling projects, each of which can carry `.autojob` files that this
manager schedules:

- [brain](https://github.com/calibrate-your-business/brain) -- a knowledge
  engine; schedule its ingest and maintenance jobs here.
- [x-bookmarks](https://github.com/calibrate-your-business/x-bookmarks) -- a
  worked example of an instrumented source repo that ships its own jobs.
- [loops](https://github.com/calibrate-your-business/loops) -- a dev-loop
  engine; schedule its recurring loops here.

## Gotchas

- **launchd's PATH is minimal.** The runtime sets its own PATH (Homebrew,
  `~/.local/bin`, etc.); a job needing a tool outside that should use an
  absolute path.
- **Headless `claude` cannot answer permission prompts.** A job that must
  commit, push, or similar has to authorize it explicitly in its prompt.
- **Absolute paths are baked into plists at install time.** Re-run
  `bin/install` after moving this repo or a source repo; `bin/status` HEALTH
  flags a plist whose targets went missing.
- **Discovery is by disk, not git.** An `.autojob` runs whether committed or
  not; merge it to make it durable and portable.

macOS-only today. See `FUTURE-WORK.md` for the OS-agnostic roadmap.
