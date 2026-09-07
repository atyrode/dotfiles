#!/usr/bin/env python3
"""Check or replace intact shared-policy envelopes without touching local bytes."""

import argparse
from contextlib import ExitStack
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import secrets
import stat
import sys


BEGIN = b"<!-- BEGIN SHARED ENGINEERING: generated; do not edit -->"
END = b"<!-- END SHARED ENGINEERING -->"
IGNORE_START = b"<!-- prettier-ignore-start -->"
IGNORE_END = b"<!-- prettier-ignore-end -->"
SOURCE = (
    b"<!-- Source: https://github.com/atyrode/dotfiles/blob/main/"
    b"modules/home/agents/engineering.md -->"
)
SENTINELS = (BEGIN, END, IGNORE_START, IGNORE_END)
LAYOUTS = {
    "repository": ("AGENTS.md",),
    "dotfiles": (
        "AGENTS.md",
        "modules/home/agents/AGENTS.md",
        "modules/home/codex/templates/repo-AGENTS.md",
    ),
}
ENVELOPE = re.compile(
    re.escape(BEGIN + b"\n\n" + IGNORE_START + b"\n" + SOURCE + b"\n")
    + rb"<!-- SHA256: (?P<digest>[0-9a-f]{64}) -->\n\n"
    + rb"(?P<payload>.*)"
    + re.escape(b"\n" + IGNORE_END + b"\n\n" + END + b"\n"),
    re.DOTALL,
)
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK


class PolicyError(Exception):
    """Invalid input or a change observed while preparing a replacement."""


@dataclass
class Target:
    name: str
    parent_fd: int
    original: bytes
    metadata: os.stat_result
    replacement: bytes


def validate_payload(payload, name):
    if not payload or payload == b"\n":
        raise PolicyError(f"{name}: policy payload is empty")
    try:
        payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PolicyError(f"{name}: policy payload must be UTF-8") from exc
    if b"\r" in payload:
        raise PolicyError(f"{name}: policy payload must use LF, not CR")
    if not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
        raise PolicyError(f"{name}: policy payload must end with exactly one LF")
    if any(sentinel in payload for sentinel in SENTINELS):
        raise PolicyError(f"{name}: policy payload contains a reserved sentinel")


def block(payload):
    digest = hashlib.sha256(payload).hexdigest().encode("ascii")
    return (
        BEGIN
        + b"\n\n"
        + IGNORE_START
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


def managed_span(document, name):
    # Counting all occurrences also rejects inline or CRLF-damaged sentinels;
    # searching only well-formed lines could silently overlook corruption.
    for sentinel in SENTINELS:
        if document.count(sentinel) != 1:
            raise PolicyError(
                f"{name}: expected exactly one {sentinel.decode('ascii')}"
            )
    start = document.index(BEGIN)
    end = document.index(END) + len(END) + 1
    if start and document[start - 1 : start] != b"\n":
        raise PolicyError(f"{name}: shared-policy BEGIN must occupy its own line")
    envelope = ENVELOPE.fullmatch(document[start:end])
    if envelope is None:
        raise PolicyError(f"{name}: malformed shared-policy envelope or boundaries")
    payload = envelope["payload"]
    validate_payload(payload, f"{name} embedded")
    if hashlib.sha256(payload).hexdigest().encode("ascii") != envelope["digest"]:
        raise PolicyError(f"{name}: embedded policy SHA256 does not match its payload")
    return start, end


def directory(path, stack):
    # Open each component without following links, not just the final name.
    # Retained directory descriptors also prevent later symlink substitution
    # from redirecting a file operation to another tree.
    absolute = Path(path)
    if not absolute.is_absolute():
        absolute = Path.cwd() / absolute
    try:
        fd = os.open(absolute.anchor, DIRECTORY_FLAGS)
        stack.callback(os.close, fd)
        for component in absolute.parts[1:]:
            fd = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            stack.callback(os.close, fd)
        return fd
    except OSError as exc:
        raise PolicyError(f"{path}: cannot open a nonsymlink directory: {exc}") from exc


def target_parent(root_fd, name, stack):
    fd = root_fd
    try:
        for component in Path(name).parts[:-1]:
            fd = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            stack.callback(os.close, fd)
        return fd
    except OSError as exc:
        raise PolicyError(f"{name}: unsafe or inaccessible parent directory: {exc}") from exc


def signature(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def regular_file(parent_fd, leaf, name):
    try:
        fd = os.open(leaf, FILE_FLAGS, dir_fd=parent_fd)
        with os.fdopen(fd, "rb") as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise PolicyError(f"{name}: expected a regular, nonsymlink file")
            content = source.read()
            after = os.fstat(source.fileno())
        if signature(before) != signature(after):
            raise PolicyError(f"{name}: file changed while being read")
        return content, after
    except OSError as exc:
        raise PolicyError(f"{name}: cannot read a regular, nonsymlink file: {exc}") from exc


def unchanged(target):
    content, metadata = regular_file(
        target.parent_fd, Path(target.name).name, target.name
    )
    if content != target.original or signature(metadata) != signature(target.metadata):
        raise PolicyError(f"{target.name}: file changed since validation; refusing replacement")


def replace(target):
    leaf = Path(target.name).name
    temporary = None
    try:
        candidate = f".{leaf}.agent-policy-{secrets.token_hex(8)}"
        fd = os.open(
            candidate,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=target.parent_fd,
        )
        temporary = candidate
        with os.fdopen(fd, "wb") as output:
            output.write(target.replacement)
            output.flush()
            os.fchmod(output.fileno(), stat.S_IMODE(target.metadata.st_mode))
            os.fsync(output.fileno())
        unchanged(target)
        os.replace(
            temporary,
            leaf,
            src_dir_fd=target.parent_fd,
            dst_dir_fd=target.parent_fd,
        )
        temporary = None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary, dir_fd=target.parent_fd)
            except OSError as exc:
                print(
                    f"agent-policy: {target.name}: temporary cleanup failed "
                    f"({temporary}): {exc}",
                    file=sys.stderr,
                )


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("check", "render", "block"):
        subparser = commands.add_parser(command)
        subparser.add_argument("--source", required=True, metavar="FILE")
        if command != "block":
            subparser.add_argument("--root", required=True, metavar="DIR")
            subparser.add_argument("--layout", required=True, choices=LAYOUTS)
    return parser.parse_args()


def main():
    args = arguments()
    replaced = []
    try:
        with ExitStack() as stack:
            source_path = Path(args.source)
            source_parent = directory(source_path.parent, stack)
            payload, _ = regular_file(source_parent, source_path.name, args.source)
            validate_payload(payload, args.source)
            expected = block(payload)
            if args.command == "block":
                sys.stdout.buffer.write(expected)
                return 0

            root_fd = directory(args.root, stack)
            targets = []
            for name in LAYOUTS[args.layout]:
                parent_fd = target_parent(root_fd, name, stack)
                original, metadata = regular_file(parent_fd, Path(name).name, name)
                start, end = managed_span(original, name)
                replacement = original
                if end - start != len(expected) or not original.startswith(expected, start):
                    replacement = original[:start] + expected + original[end:]
                targets.append(Target(name, parent_fd, original, metadata, replacement))

            stale = [target for target in targets if target.original != target.replacement]
            if args.command == "check":
                for target in stale:
                    print(f"stale: {target.name}")
                if stale:
                    return 1
            else:
                # No target is written before the entire layout is validated.
                # Recheck snapshots before writing, then again at each replace.
                for target in targets:
                    unchanged(target)
                for target in stale:
                    replace(target)
                    replaced.append(target.name)
                    print(f"updated: {target.name}")
            print(f"policy content current (SHA256: {hashlib.sha256(payload).hexdigest()})")
        return 0
    except (PolicyError, OSError) as exc:
        print(f"agent-policy: {exc}", file=sys.stderr)
        if args.command == "render":
            print(
                "agent-policy: already replaced: " + (", ".join(replaced) or "none"),
                file=sys.stderr,
            )
        return 2


if __name__ == "__main__":
    sys.exit(main())
