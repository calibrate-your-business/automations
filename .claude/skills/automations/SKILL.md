---
name: automations
description: Operate the launchd-backed automations manager -- add/remove scheduled jobs, register source repos, check status, and understand how scheduled runs execute. Use when the user asks to schedule a recurring job, add or edit an automation, register a repo with the automations manager, or debug a scheduled job that failed.
---

# automations

A launchd scheduler split into a shareable MANAGER repo (tooling + registrations)
and JOB definitions that live in the source repos they serve. The manager never
holds job bodies, so it can be public.

## Mental model

- **Manager** (this repo): `bin/` + `registrations/`.
- **Jobs**: `*.autojob` files in a source repo, under an `automations/` dir at
  the level that owns the work. Discovered as `**/automations/*.autojob` in each
  registered checkout `<repos-dir>/<NAME>` -- source repos live as siblings of
  the manager (its parent dir; override with `AUTO_REPOS_HOME`).
- **Deploy pointer** is the source repo's `main`: a job goes live when its
  `.autojob` is merged to main, then `refresh && install`.

## .autojob schema

`KEY=value`, one per line, `#` comments ok. First `=` splits (values may contain `=`).

| Field | Required | Meaning |
|---|---|---|
| `LABEL` | yes | launchd label, unique across all jobs (e.g. `com.example.thing`) |
| `SCHEDULE` | yes | `HH:MM` daily |
| `RUNTIME` | yes | `script` (COMMAND is exe+args run at WORKDIR) or `claude` (COMMAND is the prompt) |
| `COMMAND` | yes | the script invocation or the claude prompt |
| `WORKDIR` | no | relative to the owning repo root; default `.` |
| `MODEL` | no | claude runtime only: model id/alias passed to `claude --model` (e.g. `claude-sonnet-5`, `opus`); absent = the CLI's default model. Ignored (with a warning) for `RUNTIME=script` |
| `ENABLED` | no | `true` (default) or `false` (committed but not scheduled) |

## Registration schema (`registrations/<name>.repo`)

```
NAME=<name>       # -> sibling checkout <repos-dir>/<NAME>
BRANCH=main       # optional; default main
```

Gitignored by default (local-only). `git add -f` to publish participation.

## Commands

```sh
bin/status                     # schedule / launchd / health / last-success
bin/install                    # discover + reconcile all jobs onto launchd
bin/install <path-to.autojob>  # one job
bin/uninstall <label|all>
bin/refresh                    # ff-pull registered checkouts (pick up merged jobs)
bin/bootstrap                  # fresh machine: clone sources, verify prereqs, install
launchctl kickstart -k gui/$(id -u)/<label>   # trigger a run now (test)
```

## How a scheduled run executes

`launchctl` runs `/bin/bash <manager>/bin/lib.sh run <abs-.autojob>` at the
`StartCalendarInterval`. The runtime: sets a known-good PATH, exports
`SOPS_AGE_KEY_FILE` if unset, then for `script` runs `bash -c COMMAND` at
`owning-repo-root/WORKDIR`; for `claude` runs `claude -p COMMAND --allowedTools
"Read Edit Write Bash Glob Grep"` (plus `--model MODEL` when the job sets one)
at the same cwd. Writes a dated log +
`<LABEL>.last-success` under `~/Library/Logs/automations/<LABEL>/`, and posts a
macOS notification on non-zero exit.

## Gotchas

- **launchd PATH is minimal** -- the runtime sets its own `AUTO_PATH`; a job that
  needs another tool must use an absolute path or a dir on that PATH.
- **Headless `claude` cannot answer prompts** -- a job that must commit/push etc.
  has to authorize it explicitly in the prompt; `Bash` is in the allowlist.
- **Absolute paths are baked into plists at install time** -- re-run `install`
  after moving the manager or editing a job. `status` HEALTH flags a plist whose
  `lib.sh`/`.autojob` path went missing.
- **Discovery is by disk, not git** -- an `.autojob` runs whether committed or
  not; merge to main to make it durable/portable.
