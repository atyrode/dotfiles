#!/usr/bin/env python3
"""Black-box safety tests for the managed instruction envelope.

Usage: agent-policy-test.py [path-to-agent-policy.py]
Only the public CLI is exercised. Expected bytes are constructed independently:
a renderer/parser sharing the same data-loss bug must not make the tests pass.
"""

import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


RENDERER = (
    Path(sys.argv.pop(1)).resolve()
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[2] / "ci/agent-policy.py"
)
BEGIN = b"<!-- BEGIN SHARED ENGINEERING: generated; do not edit -->"
END = b"<!-- END SHARED ENGINEERING -->"
IGNORE_BEGIN = b"<!-- prettier-ignore-start -->"
IGNORE_END = b"<!-- prettier-ignore-end -->"
SOURCE = (
    b"<!-- Source: https://github.com/atyrode/dotfiles/blob/main/"
    b"modules/home/agents/engineering.md -->"
)
OLD = b"## Common engineering contract\n\n- Preserve the caller's evidence.\n"
NEW = b"## Common engineering contract\n\n- Preserve evidence and report its limits.\n"
TARGETS = (
    "AGENTS.md",
    "modules/home/agents/templates/repo-AGENTS.md",
)
PREFIX = b"# Local contract\r\n\r\nLocal introduction with non-ASCII: \xc3\xa9.\r\n\n"
SUFFIX = b"\r\n## Local ownership\r\n\r\nKeep these exact local bytes.\r\n"


def envelope(payload):
    digest = hashlib.sha256(payload).hexdigest().encode("ascii")
    return (
        BEGIN
        + b"\n\n"
        + IGNORE_BEGIN
        + b"\n"
        + SOURCE
        + b"\n<!-- SHA256: "
        + digest
        + b" -->\n\n"
        + payload
        + b"\n"
        + IGNORE_END
        + b"\n\n"
        + END
        + b"\n"
    )


class RendererTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "consumer"
        self.root.mkdir()
        self.source = self.base / "engineering.md"
        self.source.write_bytes(NEW)
        self.target = self.root / "AGENTS.md"
        self.target.write_bytes(PREFIX + envelope(OLD) + SUFFIX)

    def run_cli(self, command, expected, layout="repository", extra=()):
        args = [sys.executable, str(RENDERER), command, "--source", str(self.source)]
        if command != "block":
            args.extend(["--root", str(self.root), "--layout", layout])
        proc = subprocess.run(args + list(extra), capture_output=True, timeout=10)
        self.assertEqual(
            proc.returncode,
            expected,
            f"{args!r}\nstdout={proc.stdout!r}\nstderr={proc.stderr!r}",
        )
        return proc

    def assert_refused_without_changes(self, document, layout="repository"):
        self.target.write_bytes(document)
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        for command in ("check", "render"):
            with self.subTest(command=command):
                self.run_cli(command, 2, layout=layout)
                self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_block_emits_exact_envelope_without_touching_targets(self):
        before = self.target.read_bytes()
        self.assertEqual(self.run_cli("block", 0).stdout, envelope(NEW))
        self.assertEqual(self.target.read_bytes(), before)

    def test_stale_check_is_read_only_and_render_preserves_outside_bytes_and_mode(self):
        original = self.target.read_bytes()
        self.target.chmod(0o640)
        self.run_cli("check", 1)
        self.assertEqual(self.target.read_bytes(), original)
        self.run_cli("render", 0)
        self.assertEqual(self.target.read_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o640)
        self.run_cli("check", 0)

    def test_current_render_is_a_true_noop(self):
        self.target.write_bytes(PREFIX + envelope(NEW) + SUFFIX)
        before = self.target.stat()
        self.run_cli("render", 0)
        self.run_cli("render", 0)
        after = self.target.stat()
        self.assertEqual(self.target.read_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.assertEqual((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns))

    def test_legitimate_source_update_and_local_only_edit(self):
        self.run_cli("render", 0)
        local_edit = b"Additional local authority.\r\n" + self.target.read_bytes()
        self.target.write_bytes(local_edit)
        self.run_cli("check", 0)
        revised = NEW.replace(b"report", b"explain")
        self.source.write_bytes(revised)
        self.run_cli("check", 1)
        self.run_cli("render", 0)
        self.assertEqual(
            self.target.read_bytes(),
            b"Additional local authority.\r\n" + PREFIX + envelope(revised) + SUFFIX,
        )

    def test_repository_layout_does_not_scan_or_mutate_other_documents(self):
        unrelated = self.root / "nested/AGENTS.md"
        unrelated.parent.mkdir()
        unrelated.write_bytes(b"No managed block belongs here.\n")
        self.run_cli("render", 0)
        self.assertEqual(unrelated.read_bytes(), b"No managed block belongs here.\n")

    def test_dotfiles_layout_updates_exactly_two_targets(self):
        for name in TARGETS[1:]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(PREFIX + envelope(OLD) + SUFFIX)
        self.run_cli("check", 1, layout="dotfiles")
        self.run_cli("render", 0, layout="dotfiles")
        for name in TARGETS:
            self.assertEqual((self.root / name).read_bytes(), PREFIX + envelope(NEW) + SUFFIX)
        self.run_cli("check", 0, layout="dotfiles")

    def test_dotfiles_layout_does_not_read_or_rewrite_personal_policy(self):
        template = self.root / TARGETS[1]
        template.parent.mkdir(parents=True)
        template.write_bytes(PREFIX + envelope(OLD) + SUFFIX)
        personal = self.root / "modules/home/agents/AGENTS.md"
        destination = self.base / "personal.md"
        document = PREFIX + envelope(OLD) + SUFFIX
        destination.write_bytes(document)
        personal.symlink_to(destination)
        self.run_cli("check", 1, layout="dotfiles")
        self.run_cli("render", 0, layout="dotfiles")
        self.run_cli("check", 0, layout="dotfiles")
        self.assertTrue(personal.is_symlink())
        self.assertEqual(destination.read_bytes(), document)

    def test_dotfiles_prevalidates_all_targets_before_any_write(self):
        for bad_index in range(len(TARGETS)):
            with self.subTest(bad_target=TARGETS[bad_index]):
                for index, name in enumerate(TARGETS):
                    path = self.root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    block = envelope(OLD) if index != bad_index else envelope(OLD).replace(END, b"")
                    path.write_bytes(PREFIX + block + SUFFIX)
                before = {name: (self.root / name).read_bytes() for name in TARGETS}
                self.run_cli("render", 2, layout="dotfiles")
                self.assertEqual({name: (self.root / name).read_bytes() for name in TARGETS}, before)

    def test_missing_dotfiles_target_prevents_partial_update(self):
        (self.root / TARGETS[1]).parent.mkdir(parents=True)
        before = self.target.read_bytes()
        self.run_cli("render", 2, layout="dotfiles")
        self.assertEqual(self.target.read_bytes(), before)
        self.assertFalse((self.root / TARGETS[1]).exists())

    def test_corruption_and_every_envelope_component_are_refused(self):
        block = envelope(OLD)
        digest = hashlib.sha256(OLD).hexdigest().encode("ascii")
        cases = {
            "missing entire envelope": b"Local text only.\n",
            "empty marker pair": BEGIN + b"\n" + END + b"\n",
            "missing begin": block.replace(BEGIN + b"\n", b""),
            "missing end": block.replace(END + b"\n", b""),
            "duplicate whole envelope": block + block,
            "duplicate begin": BEGIN + b"\n" + block,
            "duplicate end": block + END + b"\n",
            "reversed markers": block.replace(BEGIN, b"TEMP").replace(END, BEGIN).replace(b"TEMP", END),
            "indented begin": block.replace(BEGIN, b" " + BEGIN),
            "indented end": block.replace(END, b" " + END),
            "begin with suffix": block.replace(BEGIN, BEGIN + b" unexpected"),
            "end with suffix": block.replace(END, END + b" unexpected"),
            "missing start guard": block.replace(IGNORE_BEGIN + b"\n", b""),
            "missing end guard": block.replace(IGNORE_END + b"\n", b""),
            "duplicate start guard": block.replace(IGNORE_BEGIN, IGNORE_BEGIN + b"\n" + IGNORE_BEGIN),
            "duplicate end guard": block.replace(IGNORE_END, IGNORE_END + b"\n" + IGNORE_END),
            "swapped guards": block.replace(IGNORE_BEGIN, b"TEMP").replace(IGNORE_END, IGNORE_BEGIN).replace(b"TEMP", IGNORE_END),
            "wrong source": block.replace(b"/blob/main/", b"/blob/other/"),
            "missing source": block.replace(SOURCE + b"\n", b""),
            "duplicate source": block.replace(SOURCE, SOURCE + b"\n" + SOURCE),
            "source before guard": block.replace(IGNORE_BEGIN + b"\n" + SOURCE, SOURCE + b"\n" + IGNORE_BEGIN),
            "missing checksum": block.replace(b"<!-- SHA256: " + digest + b" -->\n", b""),
            "wrong digest": block.replace(digest, b"0" * 64),
            "short digest": block.replace(digest, digest[:-1]),
            "uppercase digest": block.replace(digest, digest.upper()),
            "nonhex digest": block.replace(digest, b"g" * 64),
            "duplicate checksum": block.replace(b"<!-- SHA256: " + digest + b" -->", (b"<!-- SHA256: " + digest + b" -->\n") * 2),
            "tampered payload": block.replace(b"caller's", b"callers"),
            "empty payload": block.replace(OLD, b""),
            "missing initial blank": block.replace(BEGIN + b"\n\n", BEGIN + b"\n"),
            "missing payload blank": block.replace(b" -->\n\n" + OLD, b" -->\n" + OLD),
            "missing guard blank": block.replace(b"\n\n" + IGNORE_END, b"\n" + IGNORE_END),
            "missing closing blank": block.replace(IGNORE_END + b"\n\n", IGNORE_END + b"\n"),
            "extra envelope text": block.replace(SOURCE + b"\n", SOURCE + b"\nlocal text\n"),
            "CRLF inside envelope": block.replace(b"\n", b"\r\n"),
        }
        for name, corrupt in cases.items():
            with self.subTest(corruption=name):
                self.assert_refused_without_changes(PREFIX + corrupt + SUFFIX)

    def test_moved_boundaries_do_not_swallow_local_text(self):
        document = PREFIX + envelope(OLD) + SUFFIX
        cases = {
            "begin moved before local introduction": BEGIN + b"\n" + document.replace(BEGIN + b"\n", b"", 1),
            "end moved after local ownership": document.replace(END + b"\n", b"", 1) + END + b"\n",
            "begin moved into payload": document.replace(BEGIN + b"\n", b"", 1).replace(OLD, BEGIN + b"\n" + OLD),
            "end moved into payload": document.replace(END + b"\n", b"", 1).replace(OLD, OLD + END + b"\n"),
        }
        for name, corrupt in cases.items():
            with self.subTest(movement=name):
                self.assertEqual(corrupt.count(BEGIN), 1)
                self.assertEqual(corrupt.count(END), 1)
                self.assert_refused_without_changes(corrupt)

    def test_invalid_sources_never_change_a_target(self):
        cases = [b"", NEW.rstrip(b"\n"), NEW + b"\n", NEW.replace(b"\n", b"\r\n"), NEW + b"\xff\n"]
        for sentinel in (BEGIN, END, IGNORE_BEGIN, IGNORE_END):
            cases.extend([NEW + sentinel + b"\n", NEW + b"quoted " + sentinel + b" inline\n"])
        before = self.target.read_bytes()
        for payload in cases:
            with self.subTest(payload=payload):
                self.source.write_bytes(payload)
                for command in ("block", "check", "render"):
                    self.run_cli(command, 2)
                self.assertEqual(self.target.read_bytes(), before)

    def test_symlink_target_refused_even_when_destination_is_inside_root(self):
        for external in (False, True):
            with self.subTest(external=external):
                destination = (self.base if external else self.root) / "owned.md"
                destination.write_bytes(PREFIX + envelope(OLD) + SUFFIX)
                self.target.unlink()
                self.target.symlink_to(destination)
                for command in ("check", "render"):
                    self.run_cli(command, 2)
                    self.assertTrue(self.target.is_symlink())
                    self.assertEqual(destination.read_bytes(), PREFIX + envelope(OLD) + SUFFIX)

    def test_symlink_ancestor_cannot_escape_dotfiles_root(self):
        external = self.base / "external"
        (external / "home/agents/templates").mkdir(parents=True)
        for name in TARGETS[1:]:
            (external / Path(name).relative_to("modules")).write_bytes(PREFIX + envelope(OLD) + SUFFIX)
        (self.root / "modules").symlink_to(external, target_is_directory=True)
        before = self.target.read_bytes()
        for command in ("check", "render"):
            self.run_cli(command, 2, layout="dotfiles")
        self.assertEqual(self.target.read_bytes(), before)
        for name in TARGETS[1:]:
            self.assertEqual((external / Path(name).relative_to("modules")).read_bytes(), before)

    def test_nonregular_and_missing_targets_are_refused(self):
        self.target.unlink()
        self.run_cli("render", 2)
        self.assertFalse(self.target.exists())
        self.target.mkdir()
        self.run_cli("render", 2)
        self.assertTrue(self.target.is_dir())
        self.target.rmdir()
        os.mkfifo(self.target)
        self.run_cli("render", 2)
        self.assertTrue(stat.S_ISFIFO(self.target.lstat().st_mode))

    def test_invalid_invocation_cannot_select_arbitrary_targets(self):
        before = self.target.read_bytes()
        self.run_cli("render", 2, layout="elsewhere")
        self.run_cli("render", 2, extra=("--target", "../engineering.md"))
        self.run_cli("block", 2, extra=("--root", str(self.root)))
        self.assertEqual(self.target.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
