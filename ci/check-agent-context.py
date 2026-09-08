#!/usr/bin/env python3
"""Exercise real OMP instruction loading without submitting a model turn.

Only the three explicitly supplied instruction documents enter the fixtures.
Repository configuration, extensions, auth and the caller's home are never copied.
The RPC v2 transport is the upstream ready/negotiate_protocol/get_state contract.
"""

import argparse
import base64
import contextlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


TIMEOUT = 45
MAX_FRAME = 1024 * 1024
MAX_MESSAGE = 64 * 1024 * 1024
ADAPTERS = (".omp/agent/AGENTS.md", ".claude/CLAUDE.md", ".codex/AGENTS.md")
NESTED = (
    "Context acceptance: nested cwd body 472dd6bb.\n\n"
    "| Scope | Directive |\n| :------ | -------: |\n"
    "| Nested | Preserve this entire cell. |\n\n"
    "```text\n| This is code | not a table to compact |\n```\n"
)
PROFILE = "Context acceptance: named profile body 3c985bf8.\n"
OVERRIDE = "Context acceptance: explicit agent directory body 5c9ca737.\n"
CLAUDE = "Context acceptance: shadowed Claude body a52f178a.\n"
CODEX = "Context acceptance: shadowed Codex body 716ca833.\n"
CHANGED = "Context acceptance: new process revision 9e8107c5.\n"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def document(path):
    value = Path(path).read_bytes().decode("utf-8")
    require(bool(value.strip()), f"empty instruction input: {path}")
    # Never let a candidate @-import escape the instruction-only fixture.
    # Conservatively include code examples in this guard rather than maintaining
    # a second Markdown parser beside OMP's. Ordinary task links are unaffected.
    for token in re.findall(r"(?:^|[ \t])@([./~A-Za-z0-9_-][^\s]*)", value, re.MULTILINE):
        token = token.rstrip(".,;:!?)\\]}\"'")
        require(not token.startswith("/") and ".." not in Path(token).parts,
                f"instruction input has an absolute or traversing @-import: {path}")
    return value


def put(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode("utf-8"))


def clean_environment(home, config_home=None):
    """Allowlist, not a list of today's known credential variable names."""
    home = Path(home)
    home.mkdir(parents=True, exist_ok=True)
    result = {
        "PATH": os.defpath,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(config_home if config_home is not None else home / ".config"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_STATE_HOME": str(home / ".local/state"),
        "XDG_RUNTIME_DIR": str(home / "run"),
        "TMPDIR": str(home / "tmp"),
        "SHELL": "/bin/sh",
        "TERM": "dumb",
        "LANG": "C.UTF-8",
        "CI": "1",
        "NO_COLOR": "1",
        "PI_NOTIFICATIONS": "off",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "AWS_EC2_METADATA_DISABLED": "true",
    }
    for key in ("XDG_RUNTIME_DIR", "TMPDIR"):
        Path(result[key]).mkdir(mode=0o700, parents=True, exist_ok=True)
    # Nix-native binaries need these tools, but no arbitrary caller PATH entries.
    for name in ("git", "bash"):
        executable = shutil.which(name)
        if executable:
            result["PATH"] = str(Path(executable).parent) + os.pathsep + result["PATH"]
    return result


class Rpc:
    def __init__(self, executable, home, cwd, *, managed=False, profile=None, agent_dir=None,
                 user_adapters=False, config_home=None):
        self.executable = executable
        self.home = Path(home)
        self.cwd = Path(cwd)
        self.managed = managed
        self.profile = profile
        self.agent_dir = agent_dir
        self.user_adapters = user_adapters
        self.config_home = config_home
        self.process = None
        self.selector = selectors.DefaultSelector()
        self.buffer = bytearray()
        self.stderr = bytearray()
        self.counter = 0
        self.proxy = socket.socket()

    def __enter__(self):
        try:
            environment = clean_environment(self.home, self.config_home)
            # A reserved, non-listening loopback socket rejects catalog HTTP(S)
            # fetches without reaching a provider or a pre-existing local service.
            # The fixture also disables implicit localhost model discovery.
            self.proxy.bind(("127.0.0.1", 0))
            proxy = f"http://127.0.0.1:{self.proxy.getsockname()[1]}"
            environment.update({key: proxy for key in (
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"
            )})
            environment.update({"NO_PROXY": "", "no_proxy": ""})
            if self.agent_dir:
                environment["PI_CODING_AGENT_DIR"] = str(self.agent_dir)
            config = self.home / "acceptance.yml"
            put(config, json.dumps({
                "disabledProviders": ["ollama", "llama.cpp", "lm-studio"],
                "startup": {"checkUpdate": False},
                "marketplace": {"autoUpdate": False},
                "mcp": {"enabled": False},
                **({"enabledProviders": ["claude", "codex"]} if self.user_adapters else {}),
            }))
            args = [str(self.executable), "--mode", "rpc", "--no-session", "--no-tools",
                    "--no-lsp", "--no-title", "--no-skills", "--no-rules",
                    "--model", "openai/gpt-4.1", "--config", str(config), "--cwd", str(self.cwd)]
            if not self.managed:
                args.append("--no-extensions")
            if self.profile:
                args.extend(["--profile", self.profile])
            self.process = subprocess.Popen(args, cwd=self.cwd, env=environment,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE, start_new_session=True)
            self.selector.register(self.process.stdout, selectors.EVENT_READ, "stdout")
            self.selector.register(self.process.stderr, selectors.EVENT_READ, "stderr")
            ready = self.receive(time.monotonic() + TIMEOUT)
            require(ready.get("type") == "ready", "OMP did not begin with RPC ready")
            require(2 in ready.get("supportedProtocolVersions", []), "OMP lacks lossless RPC v2")
            self.request("negotiate_protocol", protocolVersion=2)
            return self
        except BaseException:
            self.close()
            raise

    def line(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "OMP RPC response timed out")
            events = self.selector.select(remaining)
            require(bool(events), "OMP RPC response timed out")
            for key, _ in events:
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    self.selector.unregister(key.fileobj)
                    if key.data == "stdout":
                        raise AssertionError("OMP closed stdout before the required RPC response; "
                                             + self.stderr.decode("utf-8", errors="replace")[-4000:])
                elif key.data == "stderr":
                    self.stderr.extend(data)
                    del self.stderr[:-8192]
                else:
                    self.buffer.extend(data)
            require(len(self.buffer) <= MAX_FRAME + 65536, "OMP exceeded physical RPC frame limit")
        line, _, remainder = self.buffer.partition(b"\n")
        self.buffer = bytearray(remainder)
        value = json.loads(line)
        require(isinstance(value, dict), "OMP emitted a non-object RPC frame")
        return value

    def receive(self, deadline):
        frame = self.line(deadline)
        if frame.get("type") != "rpc_chunk":
            return frame
        count, size, chunk_id = frame.get("count"), frame.get("byteLength"), frame.get("chunkId")
        require(isinstance(count, int) and 2 <= count <= 256, "invalid RPC chunk count")
        require(isinstance(size, int) and MAX_FRAME <= size <= MAX_MESSAGE, "invalid RPC chunk size")
        payload = bytearray()
        for index in range(count):
            if index:
                frame = self.line(deadline)
            require(frame.get("type") == "rpc_chunk" and frame.get("chunkId") == chunk_id
                    and frame.get("index") == index and frame.get("count") == count
                    and frame.get("byteLength") == size, "interrupted RPC chunk sequence")
            payload.extend(base64.b64decode(frame["data"], validate=True))
            require(len(payload) <= size, "RPC chunks exceeded declared size")
        require(len(payload) == size, "incomplete RPC chunk sequence")
        result = json.loads(payload)
        require(isinstance(result, dict), "invalid reassembled RPC frame")
        return result

    def request(self, command, **fields):
        self.counter += 1
        request_id = f"context-{self.counter}"
        self.process.stdin.write((json.dumps({"id": request_id, "type": command, **fields}) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + TIMEOUT
        while True:
            frame = self.receive(deadline)
            require(frame.get("type") not in ("agent_start", "message_start", "rpc_frame_error"),
                    "unexpected inference or RPC transport error")
            if frame.get("id") != request_id:
                continue
            require(frame.get("type") == "response" and frame.get("command") == command
                    and frame.get("success") is True, f"OMP {command} failed: {frame}")
            return frame.get("data")

    def prompt(self):
        state = self.request("get_state")
        require(isinstance(state, dict), "OMP get_state has no state")
        require(state.get("messageCount") == 0 and state.get("isStreaming") is False,
                "context inspection unexpectedly submitted a model turn")
        prompt = state.get("systemPrompt")
        if isinstance(prompt, list):
            require(all(isinstance(part, str) for part in prompt), "invalid systemPrompt parts")
            prompt = "\n".join(prompt)
        require(isinstance(prompt, str) and bool(prompt), "OMP returned no systemPrompt")
        return prompt

    def close(self):
        try:
            if self.process is not None:
                if self.process.stdin and not self.process.stdin.closed:
                    self.process.stdin.close()
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGTERM)
                    try:
                        self.process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(self.process.pid, signal.SIGKILL)
                        self.process.wait(timeout=3)
                    raise AssertionError("OMP did not shut down after RPC EOF")
                require(self.process.returncode == 0,
                        f"OMP exited {self.process.returncode}: "
                        + self.stderr.decode("utf-8", errors="replace")[-4000:])
        finally:
            self.selector.close()
            self.proxy.close()
            if self.process:
                for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                    if stream:
                        stream.close()

    def __exit__(self, kind, value, traceback):
        if kind:
            # Preserve the assertion that caused failure; teardown still runs.
            with contextlib.suppress(AssertionError, BrokenPipeError):
                self.close()
        else:
            self.close()


def rendered_document(content):
    """Account only for OMP's table presentation, not arbitrary text differences.

    Upstream packages/utils/src/prompt.ts compacts pipe-delimited rows outside
    fences, including separator padding/alignment. Keep every other byte: a
    missing directive or cell must not pass because its whitespace was stripped.
    """
    lines = []
    fenced = False
    for line in content.splitlines(keepends=True):
        stripped = line.lstrip(" \t")
        if stripped.startswith(("```", "~~~")):
            fenced = not fenced
        elif not fenced and re.fullmatch(r"\|.*\|[ \t]*\n?", stripped):
            indent = line[:len(line) - len(stripped)]
            cells = [cell.strip() for cell in stripped.strip().split("|")[1:-1]]
            if cells and all(re.fullmatch(r":?-+:?", cell) for cell in cells):
                cells = [(":" if cell.startswith(":") else "") + "---"
                         + (":" if cell.endswith(":") else "") for cell in cells]
            line = indent + "|" + "|".join(cells) + "|" + ("\n" if line.endswith("\n") else "")
        lines.append(line)
    return "".join(lines)


def check_prompt(prompt, ordered, absent=(), common=None):
    previous = -1
    for label, body in ordered:
        body = rendered_document(body)
        require(prompt.count(body) == 1, f"{label}: expected exactly one complete rendered document")
        position = prompt.index(body)
        require(position > previous, f"{label}: wrong instruction order")
        previous = position
    for label, body in absent:
        require(rendered_document(body) not in prompt, f"{label}: unexpectedly loaded")
    if common is not None:
        require(prompt.count(rendered_document(common)) == 1,
                "common policy: expected exactly one complete rendered document")


def personal_home(home, personal):
    source = home / ".config/agents/AGENTS.md"
    put(source, personal)
    for adapter in ADAPTERS:
        link = home / adapter
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(source)


def exercise(executable, root, personal, common, *, managed=False):
    with tempfile.TemporaryDirectory(prefix="agent-context-") as temporary:
        fixture = Path(temporary)
        home = fixture / "home"
        personal_home(home, personal)
        repository = home / "repository"
        put(repository / "AGENTS.md", root)
        # A fixture repository boundary, not any real project's .git/config/hooks.
        (repository / ".git").mkdir()
        (repository / "CLAUDE.md").symlink_to("AGENTS.md")
        nested = repository / "nested"
        put(nested / "AGENTS.md", NESTED)
        base = [("personal", personal), ("repository root", root)]

        def inspect(label, cwd=repository, ordered=base, absent=(), **options):
            with Rpc(executable, home, cwd, managed=managed, **options) as rpc:
                check_prompt(rpc.prompt(), ordered, absent, common if any(body == root for _, body in ordered) else None)
            print(f"ok: {'managed ' if managed else ''}{label}", flush=True)

        inspect("default root and identical adapters", absent=[("nested body", NESTED)])
        inspect("nested cwd ancestor order", nested, base + [("nested", NESTED)])
        profile_dir = home / ".omp/profiles/context-check/agent"
        put(profile_dir / "AGENTS.md", PROFILE)
        inspect("named profile", ordered=[("profile", PROFILE), ("root", root)],
                absent=[("default personal", personal)], profile="context-check")
        inspect("empty profile boundary", ordered=[("root", root)],
                absent=[("default personal", personal), ("other profile", PROFILE)], profile="context-empty")
        override_dir = home / "custom-agent"
        put(override_dir / "AGENTS.md", OVERRIDE)
        inspect("explicit agent directory", ordered=[("override", OVERRIDE), ("root", root)],
                absent=[("default personal", personal), ("other profile", PROFILE)], agent_dir=override_dir)
        outside = home / "outside"
        outside.mkdir()
        inspect("outside repository", outside, [("personal", personal)],
                [("repository", root), ("common", common), ("nested", NESTED)])

        # Distinct opt-in adapters defeat whole-file deduplication: native user
        # precedence must exclude both, not merely collapse identical documents.
        for adapter, body in ((ADAPTERS[1], CLAUDE), (ADAPTERS[2], CODEX)):
            (home / adapter).unlink()
            put(home / adapter, body)
        inspect("native user precedence", absent=[("Claude adapter", CLAUDE), ("Codex adapter", CODEX)],
                user_adapters=True)
        (home / ADAPTERS[0]).unlink()
        inspect("opted-in Claude fallback", ordered=[("Claude", CLAUDE), ("root", root)],
                absent=[("personal", personal), ("Codex", CODEX)], user_adapters=True)
        (home / ADAPTERS[1]).unlink()
        inspect("opted-in Codex fallback", ordered=[("Codex", CODEX), ("root", root)],
                absent=[("personal", personal), ("Claude", CLAUDE)], user_adapters=True)
        (home / ADAPTERS[0]).symlink_to(home / ".config/agents/AGENTS.md")

        with Rpc(executable, home, repository, managed=managed) as rpc:
            check_prompt(rpc.prompt(), base, common=common)
            put(repository / "AGENTS.md", root + "\n" + CHANGED)
            check_prompt(rpc.prompt(), base, [("unloaded edit", CHANGED)], common)
        inspect("changed file in new process", ordered=base + [("new revision", CHANGED)])

        portable_home = fixture / "portable-home"
        with Rpc(executable, portable_home, repository, managed=managed) as rpc:
            check_prompt(rpc.prompt(), [("root", root), ("new revision", CHANGED)],
                         [("personal", personal), ("nested", NESTED)], common)
        print(f"ok: {'managed ' if managed else ''}portable repository without personal policy", flush=True)
        with Rpc(executable, portable_home, outside, managed=managed) as rpc:
            check_prompt(rpc.prompt(), [], [("personal", personal), ("repository", root),
                                           ("common", common), ("nested", NESTED)])
        print(f"ok: {'managed ' if managed else ''}outside repository without personal policy", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--personal-context", required=True, type=Path)
    parser.add_argument("--common-policy", required=True, type=Path)
    parser.add_argument("--managed-omp", type=Path)
    args = parser.parse_args()
    root = document(args.repository / "AGENTS.md")
    personal = document(args.personal_context)
    common = document(args.common_policy)
    require(root.count(common) == 1, "candidate root must contain the exact common source once")
    require(common not in personal, "personal context must not duplicate common repository policy")
    require(personal not in root, "candidate root must not embed the personal document")
    for executable, managed in ((args.omp, False), (args.managed_omp, True)):
        if executable is not None:
            executable = executable.absolute()
            require(executable.is_file() and os.access(executable, os.X_OK), f"not executable: {executable}")
            exercise(executable, root, personal, common, managed=managed)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"agent context check failed: {error}", file=sys.stderr)
        sys.exit(1)
