#!/usr/bin/env python3
"""capture_sessions.py -- global agent-ops automation (owned by this repo).

Flattens Claude Code session transcripts on THIS machine into immutable raw
markdown at $SESSIONS_RAW (default $BRAIN_DB/raw/sessions/<host>/). It is NOT a
brain source; it is a machine-global automation about agent operations. No AI:
the session-learnings pass distills learnings from the raw. Delta-driven via a
per-host cursor; scrubs known secret shapes; parses defensively (the jsonl
schema is internal to Claude Code and changes between releases).

Each raw file records the session's real working directory (cwd) so the
learnings/review pass can ground its recommendations in that repo's reality.

Config (env): BRAIN_DB (default ~/Claude/brain-db), or SESSIONS_RAW to override
the raw dir outright. Extra session roots (a second account under
CLAUDE_CONFIG_DIR) go one per line in agent-ops/session-roots.local (gitignored);
~/.claude is always included.
"""
import os, sys, re, json, glob, socket, datetime, pathlib

HOME = pathlib.Path.home()
BRAIN_DB = pathlib.Path(os.environ.get("BRAIN_DB", HOME / "Claude" / "brain-db"))
HOST = socket.gethostname().split(".")[0]
RAW_DIR = pathlib.Path(os.environ.get("SESSIONS_RAW", BRAIN_DB / "raw" / "sessions")) / HOST
CURSOR = RAW_DIR / ".last-capture.json"
MIN_USER_TURNS = 6  # skip trivial sessions

HERE = pathlib.Path(__file__).resolve().parent                 # agent-ops/
ROOTS_FILE = HERE / "session-roots.local"

SCRUB = [
    (re.compile(r"age1[0-9a-z]{58}"), "[age-key]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[aws-key]"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "[gh-token]"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), "[slack-token]"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "[api-key]"),
    (re.compile(r"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._\-]{20,}"), r"\1[token]"),
    (re.compile(r"(?i)(PGPASSWORD=)\S+"), r"\1[redacted]"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[private-key]"),
]


def scrub(text):
    for pat, repl in SCRUB:
        text = pat.sub(repl, text)
    return text


def session_roots():
    """~/.claude plus any CLAUDE_CONFIG_DIR roots listed in session-roots.local."""
    roots = [HOME / ".claude"]
    if ROOTS_FILE.exists():
        for line in ROOTS_FILE.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                p = pathlib.Path(os.path.expanduser(line))
                if p.exists():
                    roots.append(p)
    return roots


def extract_text(content):
    if isinstance(content, str):
        return content, False
    if not isinstance(content, list):
        return "", False
    parts, tool_result_only = [], True
    for b in content:
        if not isinstance(b, dict):
            continue
        bt = b.get("type")
        if bt == "text":
            parts.append(b.get("text", "")); tool_result_only = False
        elif bt == "tool_use":
            parts.append(f"[tool: {b.get('name', '?')}]"); tool_result_only = False
        elif bt == "tool_result":
            parts.append("[tool result]")
    return "\n".join(p for p in parts if p), (tool_result_only and bool(parts))


def flatten(path):
    """Return (markdown, user_turn_count, cwd) for a transcript, or (None,0,'')."""
    turns, user_turns, cwd = [], 0, ""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception as e:
        print(f"  WARN unreadable {path.name}: {e}", file=sys.stderr)
        return None, 0, ""
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)                    # defensive: skip bad lines
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        if not cwd and isinstance(obj.get("cwd"), str):
            cwd = obj["cwd"]                          # the session's real working dir
        t = obj.get("type")
        if t not in ("user", "assistant"):
            continue
        msg = obj.get("message") or {}
        text, tool_only = extract_text(msg.get("content"))
        if not text.strip():
            continue
        if t == "user":
            if tool_only:
                continue                              # tool-result echo, not real input
            user_turns += 1
            turns.append("## user\n\n" + text.strip())
        else:
            turns.append("## assistant\n\n" + text.strip())
    if not turns:
        return None, 0, cwd
    return "\n\n".join(turns), user_turns, cwd


def load_cursor():
    if CURSOR.exists():
        try:
            return json.loads(CURSOR.read_text())
        except Exception:
            pass
    return {"host": HOST, "processed": {}, "count": 0}


def main():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    cur = load_cursor()
    processed = cur.get("processed", {})
    n_written = n_skipped_trivial = n_unchanged = n_scanned = 0

    for root in session_roots():
        for tp in sorted(glob.glob(str(root / "projects" / "*" / "*.jsonl"))):
            tp = pathlib.Path(tp)
            sid = tp.stem
            mtime = datetime.datetime.fromtimestamp(tp.stat().st_mtime,
                                                    datetime.timezone.utc).isoformat()
            n_scanned += 1
            if processed.get(sid) == mtime:            # unchanged since last capture
                n_unchanged += 1
                continue
            project = tp.parent.name.lstrip("-")
            body, ut, cwd = flatten(tp)
            if body is None or ut < MIN_USER_TURNS:
                n_skipped_trivial += 1
                processed[sid] = mtime                  # record so we don't re-scan
                continue
            date = mtime[:10]
            front = (
                "---\n"
                "source: sessions\n"
                f"host: {HOST}\n"
                f"project: {project}\n"
                f"cwd: {cwd}\n"
                f"session_id: {sid}\n"
                f"date: {date}\n"
                "contexts: operating\n"
                "---\n\n"
            )
            out = RAW_DIR / f"{date}__{sid}.md"
            content = front + scrub(body) + "\n"
            if out.exists() and out.read_text(encoding="utf-8") == content:
                n_unchanged += 1
            else:
                out.write_text(content, encoding="utf-8")
                n_written += 1
            processed[sid] = mtime

    cur.update({"host": HOST, "processed": processed, "count": len(processed)})
    CURSOR.write_text(json.dumps(cur, indent=0))
    print(f"session-capture[{HOST}]: scanned={n_scanned} written={n_written} "
          f"unchanged={n_unchanged} skipped_trivial={n_skipped_trivial} "
          f"tracked={len(processed)}")


if __name__ == "__main__":
    main()
