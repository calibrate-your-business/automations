#!/usr/bin/env python3
"""skills_sync.py -- global agent-ops automation (owned by this repo).

Keeps the user-level skill library current: pull the shared skills repo and
install each skill into ~/.claude/skills/ so every session in every project
sees it. The worked example of the automations pattern -- this tool is public
and generic; the private source repo URL lives in the gitignored origins.local
(the same NAME=REMOTE file bin/bootstrap reads).

Source resolution, in order:
  1. env SKILLS_REPO_URL
  2. a `skills` entry in <repo-root>/origins.local
  3. an existing git checkout at the local clone dir (used in place, no URL)
If none resolves, this is a no-op (exit 0), not an error -- a machine without
a skills source simply has nothing to sync.

Install is copy-based: every <name>/SKILL.md in the skills repo overwrites
~/.claude/skills/<name>/SKILL.md (the repo is the source of truth). Pruning is
manifest-guarded: only skills recorded in ~/.claude/skills/.managed-by-skills-sync
are ever removed, so hand-placed user-level skills are never touched.

Config (env): SKILLS_REPO_URL (source remote), SKILLS_DIR (local clone,
default ~/Claude/skills). Network failure is a warn, not a failure -- the sync
continues with whatever is on disk.
"""
import os, sys, shutil, subprocess, pathlib

HOME = pathlib.Path.home()
SKILLS_DIR = pathlib.Path(os.path.expanduser(os.environ.get("SKILLS_DIR", str(HOME / "Claude" / "skills"))))
INSTALL_DIR = HOME / ".claude" / "skills"
MANIFEST = INSTALL_DIR / ".managed-by-skills-sync"
HERE = pathlib.Path(__file__).resolve().parent                 # agent-ops/
ORIGINS = HERE.parent / "origins.local"


def origins_entry(name):
    """Value of NAME=REMOTE for `name` in origins.local (same format
    bin/lib.sh reg_field reads): first '=' splits, '#'-comments and blanks
    ignored. Returns '' if absent."""
    if not ORIGINS.exists():
        return ""
    try:
        lines = ORIGINS.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return ""
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        if key.strip() == name:
            return val.strip()
    return ""


def resolve_source():
    """Return (url, description). url may be '' when an existing checkout is
    used in place; both '' means no source resolvable."""
    url = os.environ.get("SKILLS_REPO_URL", "").strip()
    if url:
        return url, "env SKILLS_REPO_URL"
    url = origins_entry("skills")
    if url:
        return url, "origins.local skills entry"
    if (SKILLS_DIR / ".git").exists():
        return "", f"existing checkout at {SKILLS_DIR}"
    return "", ""


def sync_repo(url):
    """Clone or ff-pull the skills checkout. Best-effort: a network failure
    warns and leaves whatever is on disk. Returns 'cloned'|'pulled'|'stale'|'absent'."""
    if not SKILLS_DIR.exists():
        if not url:
            return "absent"
        r = subprocess.run(["git", "clone", url, str(SKILLS_DIR)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  WARN clone failed: {r.stderr.strip()}", file=sys.stderr)
            return "absent"
        return "cloned"
    r = subprocess.run(["git", "-C", str(SKILLS_DIR), "pull", "--ff-only"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  WARN pull failed (continuing with on-disk copy): {r.stderr.strip()}",
              file=sys.stderr)
        return "stale"
    return "pulled"


def load_manifest():
    if not MANIFEST.exists():
        return set()
    try:
        return {line.strip() for line in MANIFEST.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.startswith("#")}
    except Exception as e:
        print(f"  WARN unreadable manifest {MANIFEST}: {e}", file=sys.stderr)
        return set()


def main():
    url, source = resolve_source()
    if not source:
        print("skills-sync: no source configured (set SKILLS_REPO_URL, add a "
              "`skills=` line to origins.local, or clone the skills repo to "
              f"{SKILLS_DIR}) -- nothing to do")
        return 0

    pulled = sync_repo(url)
    if not SKILLS_DIR.is_dir():
        print(f"skills-sync: no skills checkout at {SKILLS_DIR} -- nothing to do "
              f"(source: {source})")
        return 0

    # Install: every <name>/SKILL.md in the repo overwrites the user-level copy.
    installed = []
    for skill_md in sorted(SKILLS_DIR.glob("*/SKILL.md")):
        name = skill_md.parent.name
        try:
            dest = INSTALL_DIR / name
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(skill_md, dest / "SKILL.md")
            installed.append(name)
        except Exception as e:
            print(f"  WARN could not install {name}: {e}", file=sys.stderr)

    # SAFE PRUNE: only remove a skill this tool previously installed (it is in
    # the manifest) that the source repo no longer ships. Anything not in the
    # manifest is hand-placed and untouchable.
    pruned = []
    for name in sorted(load_manifest() - set(installed)):
        target = INSTALL_DIR / name
        if target.is_dir():
            try:
                shutil.rmtree(target)
                pruned.append(name)
            except Exception as e:
                print(f"  WARN could not prune {name}: {e}", file=sys.stderr)

    # Rewrite the manifest to the current installed set.
    if installed or MANIFEST.exists():
        try:
            INSTALL_DIR.mkdir(parents=True, exist_ok=True)
            MANIFEST.write_text(
                "# Skills installed by agent-ops/skills_sync.py. Do not edit;\n"
                "# only names listed here are ever pruned by the sync.\n"
                + "".join(n + "\n" for n in installed), encoding="utf-8")
        except Exception as e:
            print(f"  WARN could not write manifest {MANIFEST}: {e}", file=sys.stderr)

    print(f"skills-sync: {pulled} installed={len(installed)} pruned={len(pruned)} "
          f"-> {INSTALL_DIR} (source: {source})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
