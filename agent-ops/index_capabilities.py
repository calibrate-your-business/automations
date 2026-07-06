#!/usr/bin/env python3
"""index_capabilities.py -- global agent-ops automation (owned by this repo).

Scans the corp repos for skills and rewrites the "Capabilities index" section of
the canonical operating memory ($BRAIN_DB/memory/MEMORY.md) so it always tracks
the live skill dirs -- never a hand-maintained catalog that rots. Runs before the
memory sync (which restores the canonical file into Claude's session slot).

Ground truth is each repo's `.claude/skills/*/SKILL.md` (or `skills/*/SKILL.md`,
e.g. loops). Only the marked section is rewritten; the curated rest is untouched.
Kept index-level (name + short purpose + repo) on a hard line budget to protect
the 25KB/200-line memory load.

Config (env): BRAIN_DB (default ~/Claude/brain-db); REPOS_HOME (default
~/Claude). Does not commit -- the memory job commits brain-db once at the end.
"""
import os, re, glob, pathlib

HOME = pathlib.Path.home()
BRAIN_DB = pathlib.Path(os.environ.get("BRAIN_DB", HOME / "Claude" / "brain-db"))
REPOS_HOME = pathlib.Path(os.environ.get("REPOS_HOME", HOME / "Claude"))
CANONICAL = BRAIN_DB / "memory" / "MEMORY.md"
START, END = "<!-- CAPABILITIES:START -->", "<!-- CAPABILITIES:END -->"
MAX_LINES = 90          # hard budget for the generated section
SKIP_DIRS = ("node_modules", ".venv", "site-packages", ".git", "_merge-test")


def corp_repos():
    out = []
    for d in sorted(REPOS_HOME.iterdir()):
        if not d.is_dir() or d.name.endswith("-worktree"):
            continue
        if d.name.startswith("_") or not (d / ".git").exists():
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
    if not CANONICAL.exists():
        print(f"  WARN no canonical memory at {CANONICAL}"); return
    text = CANONICAL.read_text(encoding="utf-8")
    if START not in text or END not in text:
        print("  WARN capability markers missing in canonical MEMORY.md"); return
    section = build_section()
    new = re.sub(re.escape(START) + r".*?" + re.escape(END),
                 f"{START}\n{section}\n{END}", text, flags=re.S)
    if new != text:
        CANONICAL.write_text(new, encoding="utf-8")
        print(f"capabilities-index: updated ({section.count(chr(10)) + 1} lines)")
    else:
        print("capabilities-index: unchanged")


if __name__ == "__main__":
    main()
