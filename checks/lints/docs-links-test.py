#!/usr/bin/env python3
"""Black-box tests for docs-links.py.

Each case builds a throwaway tree, runs the checker over it, and asserts the
exact set of links reported. The escape cases deliberately point at files that
*do* exist, so a resolver that dropped its containment guards would pass them
and fail here.

Usage: docs-links-test.py <path-to-docs-links.py>
"""
import os
import subprocess
import sys
import tempfile

checker = os.path.abspath(sys.argv[1])


def fixture(root):
    """A tree with one skill, one skill asset, and one sibling doc."""
    skill = os.path.join(root, "modules", "home", "agents", "skills", "demo")
    os.makedirs(os.path.join(skill, "references"))
    os.makedirs(os.path.join(root, "docs"))
    for path in (
        os.path.join(skill, "SKILL.md"),
        os.path.join(skill, "references", "ok.md"),
        os.path.join(root, "docs", "sibling.md"),
    ):
        open(path, "w", encoding="utf-8").close()


def report(links):
    """Run the checker over a fixture holding `links`; return the flagged ones."""
    with tempfile.TemporaryDirectory() as root:
        fixture(root)
        with open(os.path.join(root, "docs", "page.md"), "w", encoding="utf-8") as fh:
            fh.write("\n\n".join(f"[link]({link})" for link in links(root)))
        proc = subprocess.run(
            [sys.executable, checker, root], capture_output=True, text=True
        )
        flagged = {
            line.split(" -> ", 1)[1]
            for line in proc.stderr.splitlines()
            if " -> " in line
        }
        assert (proc.returncode != 0) == bool(flagged), (
            f"exit status {proc.returncode} disagrees with report:\n{proc.stderr}"
        )
        return flagged


cases = [
    ("bare skill URL resolves to SKILL.md", lambda _: ["skill://demo"], set()),
    (
        "asset inside the skill resolves",
        lambda _: ["skill://demo/references/ok.md"],
        set(),
    ),
    (
        "anchor is stripped before resolving",
        lambda _: ["skill://demo/references/ok.md#core-rules"],
        set(),
    ),
    (
        "missing skill asset is reported",
        lambda _: ["skill://demo/references/gone.md"],
        {"skill://demo/references/gone.md"},
    ),
    ("unknown skill name is reported", lambda _: ["skill://nope"], {"skill://nope"}),
    (
        "traversal out of the skill directory is reported",
        lambda _: ["skill://demo/../../../docs/sibling.md"],
        {"skill://demo/../../../docs/sibling.md"},
    ),
    (
        "absolute asset path is reported",
        lambda root: [f"skill://demo/{root}/docs/sibling.md"],
        lambda root: {f"skill://demo/{root}/docs/sibling.md"},
    ),
    (
        "traversal through the skill name is reported",
        lambda _: ["skill://../skills/demo/SKILL.md"],
        {"skill://../skills/demo/SKILL.md"},
    ),
    (
        "dot as a skill name is reported",
        lambda _: ["skill://./demo/SKILL.md"],
        {"skill://./demo/SKILL.md"},
    ),
    ("plain relative link still resolves", lambda _: ["sibling.md"], set()),
    ("stale relative link is still reported", lambda _: ["gone.md"], {"gone.md"}),
    (
        "external links and anchors are still ignored",
        lambda _: ["https://example.com", "mailto:a@b.c", "#section"],
        set(),
    ),
]

failures = []
for description, links, expected in cases:
    # The absolute-path case needs the fixture root, which only exists inside
    # report(); rebuild its expectation from the link the fixture actually used.
    captured = {}

    def record(root, links=links, captured=captured):
        captured["root"] = root
        return links(root)

    actual = report(record)
    want = expected(captured["root"]) if callable(expected) else expected
    if actual != want:
        failures.append(f"  {description}: expected {sorted(want)}, got {sorted(actual)}")

if failures:
    print("docs-links.py behaved unexpectedly:", file=sys.stderr)
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)

print(f"docs-links.py: {len(cases)} cases passed")
