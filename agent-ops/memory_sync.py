#!/usr/bin/env python3
"""memory_sync.py -- global agent-ops automation (owned by this repo).

Bidirectional daily sync of Claude Code's file-based memory, a workaround for
the auto-memory the CLI writes regardless of instruction. Two directions:

  CAPTURE  native memory files -> $BRAIN_DB/raw/agent-memory/<host>/ (an
           immutable, versioned record of whatever Claude wrote; signal for the
           session-learnings pass). Per-project scribbles are removed after a
           verified copy; the shared canonical slot is captured but not deleted.

  RESTORE  the CANONICAL memory ($BRAIN_DB/memory/MEMORY.md, the tracked source
           of truth) -> the native memory slot Claude reads at session start, so
           the next session reads the curated file rather than the day's drift.

The native slot is Claude Code's auto-memory dir. With `autoMemoryDirectory` set
in ~/.claude/settings.json all projects share one dir (env AUTO_MEMORY_DIR here,
default ~/.claude/memory); legacy per-project dirs under
~/.claude[/<cfg>]/projects/*/memory/ are also captured + swept.

Config (env): BRAIN_DB (default ~/Claude/brain-db); AUTO_MEMORY_DIR (default
~/.claude/memory). Extra config roots one per line in agent-ops/session-roots.local.
"""
import os, sys, glob, shutil, socket, datetime, pathlib

HOME = pathlib.Path.home()
BRAIN_DB = pathlib.Path(os.environ.get("BRAIN_DB", HOME / "Claude" / "brain-db"))
HOST = socket.gethostname().split(".")[0]
RAW_DIR = pathlib.Path(os.environ.get("MEMORY_RAW", BRAIN_DB / "raw" / "agent-memory")) / HOST
CANONICAL = BRAIN_DB / "memory" / "MEMORY.md"
AUTO_MEMORY_DIR = pathlib.Path(os.environ.get("AUTO_MEMORY_DIR", HOME / ".claude" / "memory"))
HERE = pathlib.Path(__file__).resolve().parent
ROOTS_FILE = HERE / "session-roots.local"


def config_roots():
    roots = [HOME / ".claude"]
    if ROOTS_FILE.exists():
        for line in ROOTS_FILE.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                p = pathlib.Path(os.path.expanduser(line))
                if p.exists():
                    roots.append(p)
    return roots


def capture_one(mf, project, delete):
    """Copy a native memory file into the store; delete native if requested and
    the copy verifies. Returns (captured, deleted)."""
    today = datetime.date.today().isoformat()
    try:
        content = mf.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        print(f"  WARN unreadable {mf}: {e}", file=sys.stderr)
        return 0, 0
    front = (
        "---\n"
        "source: agent-memory\n"
        f"host: {HOST}\n"
        f"project: {project}\n"
        f"native_file: {mf}\n"
        f"captured: {today}\n"
        "contexts: operating\n"
        "---\n\n"
    )
    payload = front + content + ("" if content.endswith("\n") else "\n")
    out = RAW_DIR / f"{today}__{project}__{mf.name}"
    out.write_text(payload, encoding="utf-8")
    verified = out.exists() and out.read_text(encoding="utf-8") == payload
    if delete and verified:
        try:
            mf.unlink(); return 1, 1
        except Exception as e:
            print(f"  WARN could not remove {mf}: {e}", file=sys.stderr)
    return (1 if verified else 0), 0


def main():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    captured = deleted = 0

    # CAPTURE: the shared canonical slot (keep it), then legacy per-project dirs
    # (sweep them -- with autoMemoryDirectory set they should stop appearing).
    if AUTO_MEMORY_DIR.exists():
        for mf in sorted(AUTO_MEMORY_DIR.glob("*.md")):
            c, d = capture_one(mf, "_canonical-slot", delete=False)
            captured += c; deleted += d
    for root in config_roots():
        for mf in sorted(glob.glob(str(root / "projects" / "*" / "memory" / "*.md"))):
            mf = pathlib.Path(mf)
            project = mf.parent.parent.name.lstrip("-")
            c, d = capture_one(mf, project, delete=True)
            captured += c; deleted += d

    # RESTORE: canonical -> the native slot Claude reads at session start.
    restored = False
    if CANONICAL.exists():
        AUTO_MEMORY_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CANONICAL, AUTO_MEMORY_DIR / "MEMORY.md")
        restored = True
    else:
        print(f"  WARN no canonical memory at {CANONICAL} -- nothing to restore", file=sys.stderr)

    # Commit brain-db changes from this job (captured raw + a regenerated
    # capabilities index) so nothing is left dirty for the next job. Best-effort.
    import subprocess
    try:
        subprocess.run(["git", "-C", str(BRAIN_DB), "add", "memory", "raw/agent-memory"],
                       check=False)
        dirty = subprocess.run(["git", "-C", str(BRAIN_DB), "status", "--porcelain",
                                "memory", "raw/agent-memory"],
                               capture_output=True, text=True).stdout.strip()
        if dirty:
            subprocess.run(["git", "-C", str(BRAIN_DB), "commit", "-q", "-m",
                            "memory: nightly sync (capture + capabilities index)"], check=False)
            subprocess.run(["git", "-C", str(BRAIN_DB), "push", "-q", "origin", "main"],
                           check=False)
            print("  brain-db: committed + pushed memory-job changes")
    except Exception as e:
        print(f"  WARN brain-db commit skipped: {e}")

    print(f"memory-sync[{HOST}]: captured={captured} swept={deleted} "
          f"restored={'yes' if restored else 'no'} -> {AUTO_MEMORY_DIR}/MEMORY.md")


if __name__ == "__main__":
    main()
