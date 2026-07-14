#!/usr/bin/env python3
"""Fail if any Markdown file has a broken internal link or stale referenced path.

Scans every .md file under the given root, resolves each non-external Markdown
link relative to the file, and checks the target exists. External links
(http/https/mailto) and pure anchors (#...) are ignored; an #anchor suffix on a
local path is stripped before resolving.
"""
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
link_re = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
broken = []

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
            resolved = os.path.normpath(os.path.join(dirpath, target))
            if not os.path.exists(resolved):
                broken.append(f"  {os.path.relpath(path, root)} -> {match.group(1)}")

if broken:
    print("Broken internal doc links / stale paths:", file=sys.stderr)
    print("\n".join(broken), file=sys.stderr)
    sys.exit(1)
