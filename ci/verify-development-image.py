#!/usr/bin/env python3
"""Exercise the published portable home in owned, offline Docker containers."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unicodedata
import uuid


def run(*args, timeout=30, check=True, input=None):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{shlex.join(args)}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def eventually(probe, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.2)
    raise RuntimeError(f"timed out: {description}")


class Fixture:
    def __init__(self, image):
        self.image = image
        self.prefix = f"development-smoke-{uuid.uuid4().hex[:12]}"
        self.containers = []
        self.sessions = []
        self.directory = Path(tempfile.mkdtemp(prefix=self.prefix + "-"))
        self.metrics = {}

    def create(self, suffix, command=(), interactive=False):
        name = f"{self.prefix}-{suffix}"
        args = ["docker", "create", "--name", name, "--network", "none"]
        if interactive:
            args += ["-it", "-e", "COLORTERM=truecolor", "-e", "CLICOLOR_FORCE=1"]
        run(*args, self.image, *command)
        self.containers.append(name)
        return name

    def start(self, name):
        start = time.monotonic()
        since = str(time.time())
        run("docker", "start", name)
        def activated():
            state = self.state(name)
            if not state["Running"]:
                raise RuntimeError(f"{name} stopped during activation: {state}\n{self.logs(name)}")
            return "APPLICATION-READY" in self.logs(name, since)
        eventually(activated, "home activation", 120)
        self.metrics[f"{name.removeprefix(self.prefix + '-')}_activation_seconds"] = round(time.monotonic() - start, 2)

    def exec(self, name, script, check=True, timeout=30, root=False):
        return run("docker", "exec", "--user", "0:0" if root else "1000:1000", name,
                   "/bin/bash", "-c", script, check=check, timeout=timeout)

    def state(self, name):
        return json.loads(run("docker", "inspect", "--format", "{{json .State}}", name).stdout)

    def logs(self, name, since=None):
        result = run("docker", "logs", "--tail", "200", *(["--since", since] if since else []), name, check=False)
        return result.stdout + result.stderr

    def stopped(self, name, timeout=15):
        eventually(lambda: not self.state(name)["Running"], "container exit", timeout)
        return self.state(name)["ExitCode"]

    def pane(self, name, width, height):
        session = f"{name}-{width}"
        self.sessions.append(session)
        env = ["env", "-u", "NO_COLOR", "-u", "CI", "TERM=xterm-256color", "COLORTERM=truecolor", "CLICOLOR_FORCE=1"]
        run("tmux", "new-session", "-d", "-s", session, "-x", str(width), "-y", str(height),
            shlex.join([*env, "docker", "start", "-ai", name]))
        return session

    def keys(self, session, *keys):
        run("tmux", "send-keys", "-t", session, *keys)

    def text(self, session, text):
        run("tmux", "send-keys", "-t", session, "-l", "--", text)

    def capture(self, session, ansi=False):
        return run("tmux", "capture-pane", "-t", session, "-p", *( ["-e"] if ansi else [])).stdout

    def expect(self, session, text, timeout=30):
        return eventually(lambda: text in self.capture(session), f"terminal displays {text!r}", timeout)

    def frame(self, session, label, width, height):
        plain = self.capture(session)
        ansi = self.capture(session, True)
        rows = plain.splitlines()
        require(len(rows) == height, f"{label}: expected {height} terminal rows, got {len(rows)}")
        def cells(row):
            return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in row)
        require(all(cells(row) <= width for row in rows), f"{label}: terminal row exceeds {width} cells")
        require("38;2;" in ansi, f"{label}: truecolor was lost")
        require("\ufffd" not in plain, f"{label}: replacement glyph")
        path = self.directory / f"{label}-{width}"
        path.with_suffix(".txt").write_text(plain)
        path.with_suffix(".ansi").write_text(ansi)
        if shutil.which("freeze"):
            run("freeze", "--language", "ansi", str(path.with_suffix(".ansi")), "-o", str(path.with_suffix(".png")),
                "--font.family", "JetBrains Mono,Symbols Nerd Font Mono", timeout=60)
        return plain

    def close(self, failed):
        if failed:
            for name in self.containers:
                (self.directory / f"{name}.log").write_text(self.logs(name))
            for session in self.sessions:
                capture = run("tmux", "capture-pane", "-t", session, "-pe", check=False)
                (self.directory / f"{session}.ansi").write_text(capture.stdout)
        for session in self.sessions:
            run("tmux", "kill-session", "-t", session, check=False)
        for name in self.containers:
            run("docker", "rm", "-f", name, check=False)
        print(f"Nonsecret captures: {self.directory}")
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                stream.write(f"captures={self.directory}\n")


def verify_terminal(f, width, height):
    name = f.create(f"terminal-{width}", interactive=True)
    start = time.monotonic()
    pane = f.pane(name, width, height)
    f.text(pane, "printf '\\nSHELL-READY:%s:%s:%s\\n' $UID $GID $options[interactive]")
    f.keys(pane, "Enter")
    f.expect(pane, "SHELL-READY:1000:1000:on", 120)
    f.metrics[f"shell_{width}_startup_seconds"] = round(time.monotonic() - start, 2)
    f.text(pane, "print history-" + f.prefix)
    f.keys(pane, "Enter", "Up", "Enter")
    eventually(lambda: f.capture(pane).splitlines().count("history-" + f.prefix) == 2, "history recall")
    f.text(pane, "mkdir -p /workspace/completion-fixture; cd /workspace; git init -q")
    f.keys(pane, "Enter")
    f.text(pane, "cd completion-fix")
    f.keys(pane, "Tab", "Enter")
    f.text(pane, "printf 'COMPLETED:%s\\n' $PWD")
    f.keys(pane, "Enter")
    f.expect(pane, "COMPLETED:/workspace/completion-fixture")
    f.text(pane, "print caféλX")
    f.expect(pane, "print caféλX")
    f.keys(pane, "Left", "BSpace")
    f.expect(pane, "print caféX")
    f.text(pane, "界")
    f.expect(pane, "print café界X")
    f.keys(pane, "Enter")
    eventually(lambda: "café界X" in f.capture(pane).splitlines(), "multibyte cursor edit")
    f.text(pane, "cd /workspace; omp")
    f.keys(pane, "Enter")
    skipped_steps = set()
    def editor_ready():
        capture = f.capture(pane)
        step = re.search(r"Setup step (\d+) of \d+", capture)
        if step and step.group(1) not in skipped_steps:
            skipped_steps.add(step.group(1))
            (f.directory / f"omp-setup-{width}-{step.group(1)}.ansi").write_text(f.capture(pane, True))
            f.keys(pane, "Escape")
            return False
        return not step and re.search(r"(?m)^╰─", capture) is not None
    eventually(editor_ready, "OMP composer ready for input", 90)
    draft = f"draft-{f.prefix}-café界"
    f.text(pane, "\x1b[200~" + draft + "\nsecond-line-λ\x1b[201~")
    f.expect(pane, draft)
    f.expect(pane, "second-line-λ")
    f.frame(pane, "omp", width, height)
    run("docker", "stop", "--time", "10", name, timeout=20)
    name = f.create(f"code-{width}",
                    ["/home/developer/.nix-profile/bin/zsh", "-lc", "git init -q; exec code"],
                    interactive=True)
    pane = f.pane(name, width, height)
    f.expect(pane, "generator", 30)
    f.expect(pane, "q quit")
    f.keys(pane, "Down")
    def selected_dial(capture):
        for row in capture.splitlines():
            control = row.split("│", 1)[0]
            if "▸" in control and re.search(r"\bmodel\s+", control):
                return control.strip()
        return None
    previous_value = eventually(lambda: selected_dial(f.capture(pane)), "Code model dial focused")
    f.frame(pane, "code-before", width, height)
    f.keys(pane, "Right")
    eventually(lambda: selected_dial(f.capture(pane)) not in (None, previous_value),
               "Code dial changes its displayed value")
    f.frame(pane, "code-after", width, height)
    f.keys(pane, "C-c")
    run("docker", "stop", "--time", "10", name, timeout=20)


def verify_runtime(f):
    command = ["/bin/bash", "-c", "trap 'exit 0' TERM INT; echo APPLICATION-READY; while :; do sleep 1; done"]
    name = f.create("runtime", command)
    f.start(name)
    eventually(lambda: "APPLICATION-READY" in f.logs(name), "supplied command starts", 120)
    f.exec(name, r'''set -eu
[ "$(id -u)" = 1000 ] && [ "$(id -g)" = 1000 ]
[ "$HOME" = /home/developer ]
[ ! -e "$HOME/.cache/nix" ] || [ "$(stat -c %u "$HOME/.cache/nix")" = 1000 ]
mkdir -p "$HOME/.config/nix" "$HOME/.config/zsh"
printf 'build-users-group =\n' > "$HOME/.config/nix/nix.conf"
printf 'export DOTFILES_IMAGE_SMOKE=preserved\n' > "$HOME/.config/zsh/local.zsh"
touch "$HOME/image-smoke-marker"
''')
    started = time.monotonic()
    run("docker", "stop", "--time", "10", name, timeout=20)
    require(f.stopped(name) == 0, "TERM handler exit 0 was not preserved")
    require(time.monotonic() - started < 10, "TERM shutdown was not prompt")
    f.start(name)
    eventually(lambda: "APPLICATION-READY" in f.logs(name), "restarted supplied command")
    f.exec(name, r'''set -eu
/home/developer/.nix-profile/bin/zsh -lic '[[ $DOTFILES_IMAGE_SMOKE = preserved ]]'
generation=$(readlink -f "$XDG_STATE_HOME/nix/profiles/home-manager")
nix path-info --store daemon "$generation"
builder=$(readlink -f /bin/bash)
printf -v expression 'builtins.derivation { name = "offline-build-user-%s"; system = builtins.currentSystem; builder = "%s"; args = [ "-c" "echo $UID > $out" ]; }' "$(date +%s%N)" "$builder"
output=$(nix build --store daemon --offline --impure --no-link --print-out-paths --expr "$expression")
uid=$(cat "$output")
[ "$uid" -ge 30001 ] && [ "$uid" -le 30032 ]
[ ! -e "$HOME/.cache/nix" ] || [ "$(stat -c %u "$HOME/.cache/nix")" = 1000 ]
if touch /nix/store/developer-must-not-write; then exit 1; fi
if touch /nix/var/nix/db/developer-must-not-write; then exit 1; fi
printf 'OFFLINE-BUILD-UID:%s\n' "$uid"
''', timeout=60)
    f.exec(name, r'''set -eu
for process in /proc/[0-9]*/comm; do
  if [ "$(cat "$process" 2>/dev/null)" = nix-daemon ]; then
    pid=${process#/proc/}; pid=${pid%/comm}; kill -KILL "$pid"; exit 0
  fi
done
exit 1
''', root=True)
    require(f.stopped(name) != 0, "unexpected daemon loss left a successful application")
    conflict = f.create("conflict", command)
    f.start(conflict)
    f.exec(conflict, 'rm "$HOME/.config/git/allowed_signers"; printf unmanaged > "$HOME/.config/git/allowed_signers"')
    run("docker", "stop", "--time", "10", conflict, timeout=20)
    run("docker", "start", conflict)
    require(f.stopped(conflict, 120) != 0, "activation overwrote an unmanaged file")
    logs = f.logs(conflict)
    require("allowed_signers" in logs and any(word in logs.lower() for word in ("collision", "existing file", "clobber", "conflict")),
            "Home Manager did not name its managed-file refusal")
    fresh = f.create("fresh", ["/bin/bash", "-c", 'test ! -e "$HOME/image-smoke-marker" && exit 37'])
    run("docker", "start", fresh)
    require(f.stopped(fresh, 120) == 37, "fresh home or supplied exit 37 contract failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    args = parser.parse_args()
    for tool in ("docker", "tmux"):
        require(shutil.which(tool), f"required driver tool: {tool}")
    fixture = Fixture(args.image)
    failed = True
    start = time.monotonic()
    try:
        inspect = json.loads(run("docker", "image", "inspect", args.image).stdout)[0]
        fixture.metrics["image_bytes"] = inspect["Size"]
        fixture.metrics["architecture"] = inspect["Architecture"]
        archive = Path(__file__).resolve().parents[1] / "result"
        if archive.is_file():
            fixture.metrics["archive_bytes"] = archive.stat().st_size
        verify_runtime(fixture)
        for width, height in ((150, 44), (100, 30)):
            verify_terminal(fixture, width, height)
        sizes = json.loads(run("docker", "inspect", "--size", *fixture.containers).stdout)
        fixture.metrics["owned_writable_bytes"] = sum(item.get("SizeRw", 0) for item in sizes)
        fixture.metrics["elapsed_seconds"] = round(time.monotonic() - start, 2)
        print(json.dumps(fixture.metrics, indent=2))
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a") as output:
                output.write("\n### Standalone development image\n```json\n" + json.dumps(fixture.metrics, indent=2) + "\n```\n")
        failed = False
    finally:
        fixture.close(failed)


if __name__ == "__main__":
    main()
