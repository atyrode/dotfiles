#!/usr/bin/env python3
"""Exercise the pin CLI with offline GitHub and Nix process boundaries."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[2] / "ci/update-preview-owner.py"
)
REVISION = "a" * 40
IDENTITY = {"owner": "atyrode", "repo": "manifold", "type": "github"}


class PreviewPinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pin = self.root / "flake.lock"
        self.original = {
            "version": 7,
            "root": "root",
            "nodes": {
                "root": {"inputs": {"manifold": "preview", "tool": "manifold"}},
                "manifold": {"original": {"type": "path", "path": "unrelated"}},
                "preview": {
                    "inputs": {"nixpkgs": ["nixpkgs"]},
                    "original": IDENTITY,
                    "locked": {
                        **IDENTITY,
                        "rev": "b" * 40,
                        "narHash": "sha256-" + "A" * 43 + "=",
                        "lastModified": 1,
                    },
                },
            },
        }
        self.pin.write_text(json.dumps(self.original, indent=2, sort_keys=True) + "\n")
        self.pin.chmod(0o640)
        production = self.root / "pkgs/manifold-agent/default.nix"
        production.parent.mkdir(parents=True)
        production.write_text("separately owned production release pin\n")
        self.before = self.snapshot()
        self.candidate = copy.deepcopy(self.original)
        self.candidate["nodes"]["preview"]["locked"].update(
            rev=REVISION, narHash="sha256-" + "B" * 43 + "=", lastModified=2
        )
        self.comparison = {"status": "ahead", "revision": REVISION}
        self.failure = None
        self.concurrent_edit = None

    def snapshot(self):
        return {
            str(path.relative_to(self.root)): path.read_bytes()
            for path in self.root.rglob("*")
            if path.is_file()
        }

    def resolve(self, args, **kwargs):
        if args[0] == "gh":
            if self.failure == "gh":
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0, json.dumps(self.comparison))
        if args[0] != "nix":
            raise AssertionError(f"Unexpected external effect: {args!r}")
        candidate = Path(args[args.index("--output-lock-file") + 1])
        if self.failure == "nix":
            candidate.write_text('{"nodes":')
            raise subprocess.CalledProcessError(1, args)
        candidate.write_text(json.dumps(self.candidate, indent=2, sort_keys=True) + "\n")
        if self.concurrent_edit is not None:
            self.pin.write_bytes(self.concurrent_edit)
        return subprocess.CompletedProcess(args, 0)

    def run_cli(self, expected, target="preview-owner", revision=REVISION):
        stdout, stderr = io.StringIO(), io.StringIO()
        previous = Path.cwd()
        os.chdir(self.root)
        try:
            with (
                patch.object(sys, "argv", [str(SCRIPT), "--target", target, "--revision", revision]),
                patch("subprocess.run", side_effect=self.resolve),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
                self.assertRaises(SystemExit) as result,
            ):
                runpy.run_path(str(SCRIPT), run_name="__main__")
            self.assertEqual(result.exception.code, expected, stderr.getvalue())
        finally:
            os.chdir(previous)
        self.assertFalse(list(self.root.glob(".preview-owner-pin-*")))

    def test_valid_pin_is_isolated_and_repeated_request_is_a_true_noop(self):
        self.run_cli(0)
        updated = json.loads(self.pin.read_bytes())
        self.assertEqual(updated["nodes"]["preview"]["locked"]["rev"], REVISION)
        updated["nodes"]["preview"]["locked"] = self.original["nodes"]["preview"]["locked"]
        self.assertEqual(updated, self.original)
        self.assertEqual(stat.S_IMODE(self.pin.stat().st_mode), 0o640)
        after = self.snapshot()
        self.assertEqual(
            {key: value for key, value in after.items() if key != "flake.lock"},
            {key: value for key, value in self.before.items() if key != "flake.lock"},
        )
        before_stat = self.pin.stat()
        self.run_cli(0)
        after_stat = self.pin.stat()
        self.assertEqual(self.snapshot(), after)
        self.assertEqual(
            (after_stat.st_ino, after_stat.st_mtime_ns),
            (before_stat.st_ino, before_stat.st_mtime_ns),
        )

    def test_out_of_scope_target_and_non_full_revision_are_refused(self):
        for target, revision in (("production", REVISION), ("preview-owner", "a" * 7)):
            with self.subTest(target=target, revision=revision):
                self.run_cli(1, target, revision)
                self.assertEqual(self.snapshot(), self.before)

    def test_unmerged_revisions_and_mismatched_proof_are_refused(self):
        for proof in (
            {"status": "behind", "revision": REVISION},
            {"status": "diverged", "revision": REVISION},
            {"status": "ahead", "revision": "c" * 40},
        ):
            with self.subTest(proof=proof):
                self.comparison = proof
                self.run_cli(1)
                self.assertEqual(self.snapshot(), self.before)

    def test_lookup_failure_and_partial_nix_output_leave_the_pin_untouched(self):
        for failure in ("gh", "nix"):
            with self.subTest(failure=failure):
                self.failure = failure
                self.run_cli(1)
                self.assertEqual(self.snapshot(), self.before)

    def test_wider_graph_changes_are_refused(self):
        self.candidate["nodes"]["manifold"]["original"]["path"] = "unexpected update"
        self.run_cli(1)
        self.assertEqual(self.snapshot(), self.before)

    def test_original_input_identity_cannot_be_rewritten(self):
        self.candidate["nodes"]["preview"]["original"]["rev"] = REVISION
        self.run_cli(1)
        self.assertEqual(self.snapshot(), self.before)

    def test_wrong_candidate_revision_or_repository_is_refused(self):
        for key, value in (("rev", "c" * 40), ("repo", "another-repository")):
            with self.subTest(key=key):
                previous = self.candidate["nodes"]["preview"]["locked"][key]
                self.candidate["nodes"]["preview"]["locked"][key] = value
                self.run_cli(1)
                self.assertEqual(self.snapshot(), self.before)
                self.candidate["nodes"]["preview"]["locked"][key] = previous

    def test_concurrent_lock_edit_is_not_overwritten(self):
        edited = copy.deepcopy(self.original)
        edited["nodes"]["manifold"]["original"]["path"] = "operator edit"
        self.concurrent_edit = json.dumps(edited).encode()
        self.run_cli(1)
        expected = {**self.before, "flake.lock": self.concurrent_edit}
        self.assertEqual(self.snapshot(), expected)

    def test_failed_atomic_publication_leaves_the_pin_untouched(self):
        with patch("os.replace", side_effect=OSError("publication refused")):
            self.run_cli(1)
        self.assertEqual(self.snapshot(), self.before)


if __name__ == "__main__":
    unittest.main()
