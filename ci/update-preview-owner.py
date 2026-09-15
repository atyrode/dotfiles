#!/usr/bin/env python3
"""Publishable lock metadata for the preview input, never machine activation."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


IDENTITY = {"owner": "atyrode", "repo": "manifold", "type": "github"}


def refresh(target, revision):
    if target != "preview-owner":
        raise ValueError("only target=preview-owner is supported")
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("revision must be a full lowercase Git commit SHA")

    path = Path("flake.lock")
    original_bytes = path.read_bytes()
    original = json.loads(original_bytes)
    node_name = original["nodes"][original["root"]]["inputs"]["manifold"]
    if not isinstance(node_name, str):
        raise ValueError("the root manifold input must be a direct lock node")
    node = original["nodes"][node_name]
    if node["original"] != IDENTITY or any(
        node["locked"].get(key) != value for key, value in IDENTITY.items()
    ):
        raise ValueError("the manifold input has an unexpected source identity")

    comparison = json.loads(
        subprocess.run(
            [
                "gh",
                "api",
                f"repos/atyrode/manifold/compare/{revision}...main",
                "--jq",
                "{status, revision: .base_commit.sha}",
            ],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            timeout=120,
        ).stdout
    )
    if comparison.get("revision") != revision or comparison.get("status") not in (
        "ahead",
        "identical",
    ):
        raise ValueError("revision is not proven reachable from atyrode/manifold main")
    if node["locked"]["rev"] == revision:
        return False

    # Let Nix own lock serialization and dependency resolution. A separate output
    # keeps even a failed fetch or an unexpectedly wider lock update unpublished.
    with tempfile.TemporaryDirectory(
        prefix=".preview-owner-pin-", dir=path.resolve().parent
    ) as directory:
        candidate = Path(directory) / "flake.lock"
        subprocess.run(
            [
                "nix",
                "flake",
                "lock",
                "--override-input",
                "manifold",
                f"github:atyrode/manifold/{revision}",
                "--output-lock-file",
                str(candidate),
            ],
            check=True,
            timeout=600,
        )
        proposed = json.loads(candidate.read_bytes())
        locked = proposed["nodes"][node_name]["locked"]
        if locked.get("rev") != revision or any(
            locked.get(key) != value for key, value in IDENTITY.items()
        ):
            raise ValueError("Nix did not lock the requested Manifold source")
        proposed["nodes"][node_name]["locked"] = node["locked"]
        if proposed != original:
            raise ValueError(
                "Nix changed more than the preview input's locked metadata; "
                "a separate lock-graph review is required"
            )
        if path.read_bytes() != original_bytes:
            raise ValueError("flake.lock changed during resolution; refusing to overwrite it")
        candidate.chmod(stat.S_IMODE(path.stat().st_mode))
        os.replace(candidate, path)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        changed = refresh(args.target, args.revision)
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Preview source pin refused: {error}", file=sys.stderr)
        return 1
    if changed:
        print(f"Updated only the preview Manifold source pin to {args.revision}.")
    else:
        print(f"Preview Manifold source is already pinned to {args.revision}; no change.")
    print("No machine activation or owner restart was performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
