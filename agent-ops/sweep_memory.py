#!/usr/bin/env python3
"""sweep_memory.py -- global agent-ops automation (owned by this repo).

A workaround for Claude Code's compulsion to write native per-project memory
files regardless of instruction. Sweeps every ~/.claude/projects/<proj>/memory/
markdown file into the durable store as immutable raw, then REMOVES the native
file (after a verified copy) so the untracked side-channel stays empty and the
content flows into the reviewed pipeline instead.

Config (env): BRAIN_DB (default ~/Claude/brain-db), or MEMORY_RAW to override
the raw dir. Extra config roots (CLAUDE_CONFIG_DIR accounts) go one per line in
agent-ops/session-roots.local (shared with capture_sessions); ~/.claude always
included.
"""
import os, sys, glob, socket, datetime, pathlib

HOME = pathlib.Path.home()
BRAIN_DB = pathlib.Path(os.environ.get("BRAIN_DB", HOME / "Claude" / "brain-db"))
HOST = socket.gethostname().split(".")[0]
RAW_DIR = pathlib.Path(os.environ.get("MEMORY_RAW", BRAIN_DB / "raw" / "agent-memory")) / HOST
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


def main():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today().isoformat()
    swept = kept = 0
    for root in config_roots():
        for mf in glob.glob(str(root / "projects" / "*" / "memory" / "*.md")):
            mf = pathlib.Path(mf)
            project = mf.parent.parent.name.lstrip("-")
            try:
                content = mf.read_text(encoding="utf-8", errors="replace")
            except Exception as e:
                print(f"  WARN unreadable {mf}: {e}", file=sys.stderr)
                continue
            out = RAW_DIR / f"{today}__{project}__{mf.name}"
            front = (
                "---\n"
                "source: agent-memory\n"
                f"host: {HOST}\n"
                f"project: {project}\n"
                f"native_file: {mf}\n"
                f"swept: {today}\n"
                "contexts: operating\n"
                "---\n\n"
            )
            payload = front + content + ("\n" if not content.endswith("\n") else "")
            out.write_text(payload, encoding="utf-8")
            # Delete native ONLY after a verified on-disk copy.
            if out.exists() and out.read_text(encoding="utf-8") == payload:
                try:
                    mf.unlink()
                    swept += 1
                except Exception as e:
                    print(f"  WARN could not remove {mf}: {e}", file=sys.stderr); kept += 1
            else:
                kept += 1
    print(f"memory-sweep[{HOST}]: swept={swept} kept={kept} -> {RAW_DIR}")


if __name__ == "__main__":
    main()
