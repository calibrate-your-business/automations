#!/usr/bin/env python3
"""index_capabilities.py -- global agent-ops automation (owned by this repo).

Scans THIS machine's corp repos for skills and writes a machine-LOCAL catalog to
$BRAIN_DB/memory/CAPABILITIES.md, reflecting the repo/skill set actually checked
out on this host. The catalog is regenerated per machine and is gitignored: it
is a machine-DERIVED artifact and must never enter shared, pushed canon. (A
shared, pushed index diverges the moment two machines have different repos
checked out -- which is exactly what it used to do when it rewrote MEMORY.md.)
The canonical MEMORY.md stays machine-agnostic and only points at this file;
memory_sync restores CAPABILITIES.md into the session slot alongside it.

Ground truth is each repo's `.claude/skills/*/SKILL.md` (or `skills/*/SKILL.md`,
e.g. loops). Only PRIMARY checkouts are scanned -- a worktree's `.git` is a FILE
and a primary checkout's is a DIRECTORY, so worktrees (and non-repos) are skipped
and a dev worktree never shows up as a phantom repo.

Config (env): BRAIN_DB (default ~/Claude/brain-db); REPOS_HOME (default
~/Claude). Never commits or pushes; writes only the local CAPABILITIES.md.
"""
import os, re, socket, pathlib

HOME = pathlib.Path.home()
BRAIN_DB = pathlib.Path(os.environ.get("BRAIN_DB", HOME / "Claude" / "brain-db"))
REPOS_HOME = pathlib.Path(os.environ.get("REPOS_HOME", HOME / "Claude"))
OUTPUT = BRAIN_DB / "memory" / "CAPABILITIES.md"
HOST = socket.gethostname().split(".")[0]
MAX_LINES = 90          # hard budget for the generated list


def corp_repos():
    out = []
    for d in sorted(REPOS_HOME.iterdir()):
        if not d.is_dir() or d.name.startswith("_") or d.name.endswith("-worktree"):
            continue
        # PRIMARY checkouts only: a worktree's .git is a FILE (gitdir pointer),
        # a primary checkout's is a DIRECTORY. This also excludes non-repos.
        if not (d / ".git").is_dir():
            continue
        out.append(d)
    return out


def parse_skill(p):
    """Return (name, purpose) from a SKILL.md, or (None, None)."""
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return None, None
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    fm = m.group(1) if m else text[:400]
    name = re.search(r"^name:\s*(.+)$", fm, re.M)
    desc = re.search(r"^description:\s*(.+)$", fm, re.M)
    name = name.group(1).strip().strip('"').strip() if name else p.parent.name
    purpose = desc.group(1).strip().strip('"').strip() if desc else ""
    # first sentence / clause, trimmed to ~14 words
    purpose = re.split(r"(?<=[.;])\s|  ", purpose)[0]
    words = purpose.split()
    if len(words) > 14:
        purpose = " ".join(words[:14]) + "..."
    return name, purpose


def skills_for(repo):
    # os.walk (not glob) so we descend into dot-dirs like .claude. Only count
    # ACTIVE skills: a SKILL.md whose path goes through `.claude/skills/` or a
    # top-level `skills/` (loops). Excludes research/vault/archive artifacts
    # (e.g. rejected PR-workflow research) and vendored trees.
    found = {}
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames
                       if d not in ("node_modules", ".venv", ".git")
                       and "site-packages" not in d]
        if "SKILL.md" not in filenames:
            continue
        norm = "/" + dirpath.replace(str(repo), "").strip("/") + "/"
        if "/.claude/skills/" not in norm and "/skills/" not in norm:
            continue
        if any(seg in norm for seg in ("/research/", "/vault/", "/archive/", "/_merge")):
            continue
        name, purpose = parse_skill(pathlib.Path(dirpath) / "SKILL.md")
        if name and name not in found:
            found[name] = purpose
    return dict(sorted(found.items()))


def build_section():
    lines, n = [], 0
    for repo in corp_repos():
        sk = skills_for(repo)
        if not sk:
            continue
        lines.append(f"**{repo.name}**")
        n += 1
        for name, purpose in sk.items():
            if n >= MAX_LINES:
                lines.append("- ...(truncated; see each repo's `.claude/skills/`)")
                return "\n".join(lines)
            lines.append(f"- `{name}`" + (f" -- {purpose}" if purpose else ""))
            n += 1
        lines.append("")
        n += 1
    return "\n".join(lines).rstrip() or "(no skills found)"


def main():
    section = build_section()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    body = (
        f"# Capabilities index ({HOST}) -- generated, machine-local, do not edit\n\n"
        "Skills across the corp repos checked out on THIS machine, and when to\n"
        "reach for them. Regenerated nightly by `agent-ops/index_capabilities.py`\n"
        "from each repo's `.claude/skills/` (or `skills/`). This file is gitignored\n"
        "and per-machine; the shared canonical MEMORY.md only points here.\n\n"
        f"{section}\n"
    )
    OUTPUT.write_text(body, encoding="utf-8")
    print(f"capabilities-index[{HOST}]: wrote {OUTPUT} ({section.count(chr(10)) + 1} skill lines)")


if __name__ == "__main__":
    main()
