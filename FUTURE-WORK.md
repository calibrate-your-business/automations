# FUTURE-WORK

Roadmap items deliberately deferred. Not built now.

## OS-agnostic support (Linux, Windows)

macOS/launchd is the only scheduler backend today. The `.autojob` schema, the
registration format, discovery, and the commit-mode model are already
platform-neutral. The macOS-specific surfaces to abstract behind interfaces
before Linux/Windows support:

1. **Scheduler backend** -- currently launchd (plist render, `launchctl
   bootstrap/bootout/kickstart/print`, `StartCalendarInterval`, `gui/<uid>`
   domain, `~/Library/LaunchAgents/`). Abstract to an interface
   `install(label, schedule, cmd)` / `remove(label)` / `state(label)`; back it
   with launchd (macOS), systemd user timers with `Persistent=true` or cron
   (Linux), Task Scheduler (Windows).
2. **Notifier** -- currently `osascript display notification`. Abstract to
   `notify(title, msg)`; back with osascript (macOS), `notify-send`/D-Bus
   (Linux), a PowerShell toast (Windows).
3. **Path / dir resolution** -- currently hardcodes `~/Library/Logs`,
   `~/Library/LaunchAgents`, `~/.config/sops/age/keys.txt`, and Homebrew dirs in
   `AUTO_PATH`. Move to a platform path-resolver (XDG on Linux,
   `%APPDATA%`/`%LOCALAPPDATA%` on Windows) and tool discovery instead of a
   hardcoded PATH.
4. **Shell / runtime** -- `#!/usr/bin/env bash` + bash 3.2 constructs; Windows
   has no bash. Keep POSIX-sh for macOS/Linux and add a PowerShell port, or
   reimplement the runtime in a portable language (Go/Python) with the schedulers
   as pluggable backends.
5. **Permissioning** -- macOS Full Disk Access (TCC) and the `claude -p`
   allowlist; document per-platform equivalents.
6. **Missed-run semantics** -- launchd runs a missed calendar slot on next wake;
   systemd uses `Persistent=`; Task Scheduler has its own settings. Document per
   backend.

## Other

- `bin/doctor` (or a `status --strict`): grep tracked files for known-sensitive
  tokens and exit nonzero, asserting the publish-safe invariant before the repo
  is made public.
- Per-run freshness option: currently `refresh` is a deliberate step, keeping
  scheduled runs network-free. If "always latest at fire time" is wanted, offer
  a scheduled refresh or an opt-in ff-pull inside the runtime.
