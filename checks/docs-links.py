#!/usr/bin/env python3
"""Fail if any Markdown file has a broken internal link or stale referenced path.

Scans every .md file under the given root, resolves each non-external Markdown
link relative to the file, and checks the target exists. External links
(http/https/mailto) and pure anchors (#...) are ignored; an #anchor suffix on a
local path is stripped before resolving.

`skill://<name>[/<path>]` targets are resolved the way the agent runtime
resolves them -- against the skill directory that owns <name>, defaulting to its
SKILL.md -- so a renamed skill or a moved asset fails here instead of at
runtime. An unknown skill name is reported as broken.
"""
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
link_re = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
skill_re = re.compile(r"^skill://([^/]+)(?:/(.*))?$")
# Every tree that contributes skills to a session, so a skill:// link is checked
# against the same set of names the runtime will discover.
skill_roots = ["agents/skills", "agents/desktop-skills", ".agents/skills"]
# A skill:// target the runtime would refuse. Distinct from None, which means
# "not a skill URL at all" and falls back to plain relative resolution.
REJECTED = object()
broken = []


def resolve_skill(target):
    """Map a skill:// target onto disk, or None when it is not a skill URL.

    Mirrors the runtime's guards, so this check can never greenlight a URL the
    agent will refuse to open. The skill name must name a direct child of a
    declared skill root, and the asset path must stay inside that child.
    """
    match = skill_re.match(target)
    if not match:
        return None
    name, relative = match.group(1), match.group(2) or "SKILL.md"

    def owning_dir(skill_root):
        """`name`'s directory under `skill_root`, or None when it escapes it."""
        parent = os.path.abspath(os.path.join(root, skill_root))
        base = os.path.abspath(os.path.join(parent, name))
        return base if os.path.dirname(base) == parent else None

    bases = [base for base in map(owning_dir, skill_roots) if base is not None]
    if not bases:
        # A name like ".." that resolves outside every skill root.
        return REJECTED
    # Unknown skill names fall back to the canonical generic root, so the
    # report names the place the skill was expected to live.
    base = next((base for base in bases if os.path.isdir(base)), bases[0])
    resolved = os.path.abspath(os.path.join(base, relative))
    if resolved != base and not resolved.startswith(base + os.sep):
        return REJECTED
    return resolved


for dirpath, _dirs, files in os.walk(root):
    if "/.git" in dirpath:
        continue
    for name in files:
        if not name.endswith(".md"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="ignore") as fh:
            text = fh.read()
        for match in link_re.finditer(text):
            target = match.group(1).strip()
            if re.match(r"^(https?:|mailto:|#)", target):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            resolved = resolve_skill(target)
            if resolved is None:
                resolved = os.path.normpath(os.path.join(dirpath, target))
            if resolved is REJECTED or not os.path.exists(resolved):
                broken.append(f"  {os.path.relpath(path, root)} -> {match.group(1)}")

if broken:
    print("Broken internal doc links / stale paths:", file=sys.stderr)
    print("\n".join(broken), file=sys.stderr)
    sys.exit(1)
