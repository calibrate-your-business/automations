# FUTURE-WORK

Roadmap items deliberately deferred. Not built now.

## OS-agnostic support

**macOS (launchd) and Linux (systemd user timers) are supported.** The scheduler
backend, notifier, and path resolution are abstracted behind a platform layer in
`bin/lib.sh` (`AUTO_OS`, `sched_install`/`sched_remove`/`sched_state`/`sched_health`,
`notify`, and the `AUTO_LOG_BASE`/`AUTO_UNIT_DIR`/`AUTO_PATH` resolver). The
`.autojob` schema, registration format, discovery, and commit-mode model are
platform-neutral and shared. Items 1-3 and 6 below are done for Linux/systemd;
what remains:

1. ~~Scheduler backend~~ -- **done** for Linux (systemd `oneshot` `.service` +
   `.timer` with `OnCalendar` + `Persistent=true`, managed via `systemctl
   --user`). Remaining: **Windows** Task Scheduler, and an optional **cron
   fallback** for Linux boxes without a systemd user manager (no per-job state
   or missed-run replay -- weaker parity, hence not the default).
2. ~~Notifier~~ -- **done**: `notify(title,msg)` dispatches `osascript` (macOS)
   / `notify-send` (Linux). Remaining: a PowerShell toast for Windows.
3. ~~Path / dir resolution~~ -- **done**: platform resolver picks Library dirs +
   Homebrew PATH on macOS, XDG dirs (`~/.local/state`, `~/.config/systemd/user`)
   + a distro PATH on Linux. Remaining: `%APPDATA%`/`%LOCALAPPDATA%` for Windows,
   and true tool discovery instead of a hardcoded PATH.
4. **Shell / runtime** -- `#!/usr/bin/env bash` + bash 3.2 constructs; Windows
   has no bash. Keep POSIX-sh for macOS/Linux and add a PowerShell port, or
   reimplement the runtime in a portable language (Go/Python) with the schedulers
   as pluggable backends.
5. **Permissioning** -- the `claude -p` allowlist carries over to every backend.
   macOS Full Disk Access (TCC) has no Linux equivalent; on Linux the analog is
   `loginctl enable-linger` so user timers run while logged out. Document Windows.
6. ~~Missed-run semantics~~ -- **done** for Linux (`Persistent=true` replays a
   missed calendar slot on next boot, the launchd "on next wake" analog).
   Remaining: document Task Scheduler behavior for Windows.

## Other

- `bin/doctor` (or a `status --strict`): grep tracked files for known-sensitive
  tokens and exit nonzero, asserting the publish-safe invariant before the repo
  is made public.
- Per-run freshness option: currently `refresh` is a deliberate step, keeping
  scheduled runs network-free. If "always latest at fire time" is wanted, offer
  a scheduled refresh or an opt-in ff-pull inside the runtime.
