# automations

A standalone, shareable manager for scheduled jobs on macOS (launchd). This repo
holds only **tooling** and **registrations** -- the actual job definitions live
in the source repos they serve, so this repo can be public without leaking what
any job does.

## Model

- **Manager (this repo)** = `bin/` tooling + `registrations/`. Nothing here
  reveals a job's schedule, command, or purpose.
- **Jobs** = `*.autojob` files that live in the SOURCE repos, in an
  `automations/` directory at whatever level owns the work (repo-root for a
  single product, or deep in the tree for a subproject-scoped job). Discovered on
  disk as `**/automations/*.autojob`.
- **Registration** = `registrations/<name>.repo` (`NAME` + optional `BRANCH`).
  It only names a source repo; the manager reads `~/Claude/<NAME>` for that
  repo's jobs.
- **Runtime** = `bin/lib.sh run <file>` (called by launchd). Sets a known-good
  PATH, points sops at the age key, runs the job as a shell script or a headless
  `claude -p` with a bounded tool allowlist, logs to
  `~/Library/Logs/automations/<LABEL>/`, and notifies on failure.

## Privacy invariant

- **Registrations are gitignored by default** (`registrations/*.repo`). A
  registration on disk works fully but is invisible to anyone who clones this
  repo. `git add -f registrations/<name>.repo` publishes that repo's
  participation (only its logical name -- never its jobs).
- **Job bodies never enter this repo.** They live in their source repos.
- **Remote URLs stay out** of git -- in the gitignored `origins.local`.

## Quickstart

```sh
bin/bootstrap     # clone any missing source repos (from origins.local), verify
                  # prereqs (age key, claude, jq), then install
bin/status        # single pane of glass: schedule / launchd state / HEALTH / last-success
```

## Add a source repo

1. `registrations/<name>.repo`:
   ```
   NAME=<name>
   BRANCH=main
   ```
   Leave it gitignored (local-only) for a private repo; `git add -f` it to
   publish participation for a public one.
2. If a fresh machine should clone it, add `<name>=<git-remote-url>` to
   `origins.local`.

## Add a job

1. In the source repo, create `<some/path>/automations/<name>.autojob`:
   ```
   LABEL=com.example.my-job
   SCHEDULE=09:00        # HH:MM
   RUNTIME=script        # or: claude
   COMMAND=./do-thing.sh # script: exe+args resolved at WORKDIR; claude: the prompt
   WORKDIR=some/path     # relative to the owning repo root; default .
   MODEL=claude-sonnet-5 # optional; claude runtime only -- model id/alias passed
                         # to `claude --model`; absent = the CLI's default model
   ENABLED=true          # optional; false = committed but not scheduled
   ```
   Put the `automations/` dir at the level that owns the job.
2. Merge it to the source repo's `main` (the deploy pointer).
3. `bin/refresh && bin/install` -> `bin/status` confirms it loaded.

## Commands

| Command | What it does |
|---|---|
| `bin/install [all]` | discover `*.autojob`, render + reconcile launchd plists |
| `bin/install <path>` | install one `.autojob` |
| `bin/uninstall <label\|all>` | remove from launchd |
| `bin/status` | schedule / launchd / health / last-success table |
| `bin/refresh` | ff-pull each registered checkout to pick up merged jobs |
| `bin/bootstrap` | fresh machine: clone sources, verify prereqs, install |

macOS-only today. See `FUTURE-WORK.md` for the OS-agnostic roadmap.
