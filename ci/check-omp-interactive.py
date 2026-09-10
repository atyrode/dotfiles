#!/usr/bin/env python3
"""Exercise packaged OMP's terminal paste handshake without credentials/model turns."""

import argparse
import base64
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time


spec = importlib.util.spec_from_file_location(
    "agent_context", Path(__file__).with_name("check-agent-context.py")
)
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)
TIMEOUT = 45
ENABLE = b"\x1b[?5522h"
MIME = base64.b64encode(b"image/png")
PNG = b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="


def packet(metadata, payload=b""):
    return b"\x1b]5522;type=read:" + metadata + b";" + payload + b"\x07"


def stop_process_group(process):
    # Reap the whole process group before its temporary HOME is removed.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
    deadline = time.monotonic() + 5
    while True:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        if time.monotonic() >= deadline:
            raise AssertionError("interactive fixture process group did not terminate")
        time.sleep(0.02)


def exercise(executable, args, name):
    with tempfile.TemporaryDirectory(prefix="omp-interactive-") as temporary:
        root = Path(temporary)
        home = root / "home"
        cwd = root / "project"
        cwd.mkdir()
        environment = context.clean_environment(home)
        for key in ("CI", "NO_COLOR"):
            environment.pop(key, None)
        environment.update({"TERM": "xterm-256color", "COLORTERM": "truecolor"})
        config = home / ".omp/agent/config.yml"
        context.put(config, json.dumps({
            "modelRoles": {"default": "openai/gpt-4.1"},
            "disabledProviders": ["ollama", "llama.cpp", "lm-studio"],
            "startup": {"checkUpdate": False, "setupWizard": False},
            "marketplace": {"autoUpdate": False},
            "mcp": {"enabled": False},
        }))
        # Restricted launchers deliberately replace HOME; their supported project
        # config supplies the same credential-free fixture without changing argv.
        context.put(cwd / ".omp/config.yml", config.read_text())
        with socket.socket() as proxy:
            proxy.bind(("127.0.0.1", 0))
            address = f"http://127.0.0.1:{proxy.getsockname()[1]}"
            environment.update({key: address for key in (
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy",
            )})
            environment.update({"NO_PROXY": "", "no_proxy": ""})
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 44, 150, 0, 0))
            process = None
            try:
                process = subprocess.Popen(
                    [executable, *[str(cwd) if arg == "{cwd}" else arg for arg in args]],
                    cwd=cwd, env=environment, stdin=slave, stdout=slave, stderr=slave,
                    start_new_session=True,
                    preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0),
                )
                os.close(slave)
                slave = None
                output = bytearray()
                with selectors.DefaultSelector() as selector:
                    selector.register(master, selectors.EVENT_READ)

                    def expect(needle):
                        deadline = time.monotonic() + TIMEOUT
                        while needle not in output:
                            if time.monotonic() >= deadline or process.poll() is not None:
                                raise AssertionError(
                                    f"{name}: missing {needle!r}; exit={process.poll()}; "
                                    f"isolated terminal tail={bytes(output[-3000:])!r}"
                                )
                            if selector.select(0.1):
                                try:
                                    chunk = os.read(master, 65536)
                                except OSError:
                                    chunk = b""
                                output.extend(chunk)
                                if len(output) > 4 * 1024 * 1024:
                                    raise AssertionError(f"{name}: excessive terminal output")

                    expect(ENABLE)
                    # An opt-in alone is insufficient: prove the live input controller
                    # consumes a MIME offer and asks the terminal for its PNG bytes.
                    os.write(master, packet(b"status=OK") +
                             packet(b"status=DATA:mime=" + MIME) + packet(b"status=DONE"))
                    expect(b"\x1b]5522;type=read:mime=" + MIME + b"\x07")
                    output.clear()
                    os.write(master, packet(b"status=DATA:mime=" + MIME, PNG) +
                             packet(b"status=DONE"))
                    expect(b"#1")
                print(f"PASS {name}: paste opt-in, PNG request and composer attachment")
            finally:
                # Release the terminal before waiting: no reader remains to drain
                # a child's final screen writes, particularly on Darwin PTYs.
                os.close(master)
                if slave is not None:
                    os.close(slave)
                if process is not None:
                    stop_process_group(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--configured", required=True)
    options = parser.parse_args()
    exercise(options.raw, ["--cwd", "{cwd}"], "raw explicit cwd")
    for command, args, name in (
        ("omp", [], "plain bare startup"),
        ("omp", ["--no-session"], "plain ephemeral startup"),
        ("omp-managed", [], "managed bare startup"),
        ("ompu", [], "restricted bare startup"),
    ):
        exercise(str(Path(options.configured) / "bin" / command), args, name)


if __name__ == "__main__":
    main()
