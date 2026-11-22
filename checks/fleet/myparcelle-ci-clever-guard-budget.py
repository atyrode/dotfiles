#!/usr/bin/env python3
"""Exercise the cost guard's live monthly budget policy, offline, in temp directories.

argv: path of myparcelle-ci-clever-guard.py. The guard's own functions run; the
Clever API, GitHub, Discord, systemd and syslog are fixtures that record what the
guard asks of them. The module's policy constants are pointed at a temp
directory and at this process's uid (the production root owner needs root).
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import stat
from datetime import datetime
from unittest import mock

PATH = sys.argv[1]
sys.argv = ["guard"]
spec = importlib.util.spec_from_file_location("guard", PATH)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

ROOT = tempfile.mkdtemp(prefix="budget-check-")
UID = os.getuid()
guard.BUDGET_OWNER_UID = UID
guard.BUDGET_FILENAME = "monthly-eur"
counter = [0]


def fresh_directory(content=None, mode=0o644, directory_mode=0o755):
    """A policy directory (and file, when `content` is given), patched in as the guard's."""
    counter[0] += 1
    directory = os.path.join(ROOT, f"case-{counter[0]}")
    os.mkdir(directory)
    os.chmod(directory, directory_mode)
    if content is not None:
        file = os.path.join(directory, guard.BUDGET_FILENAME)
        with open(file, "wb") as target:
            target.write(content if isinstance(content, bytes) else content.encode())
        os.chmod(file, mode)
    guard.BUDGET_DIRECTORY = directory
    return directory


def policy_file():
    return os.path.join(guard.BUDGET_DIRECTORY, guard.BUDGET_FILENAME)


def snapshot(directory):
    """Every entry of the directory with its content, to prove nothing changed."""
    found = {}
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        found[name] = None if os.path.isdir(path) or os.path.islink(path) else open(path, "rb").read()
    return found


def rejected(label):
    try:
        guard.read_monthly_budget()
    except guard.BudgetPolicyError:
        return
    raise AssertionError(f"{label}: the policy was accepted")


def run_command(args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = guard.budget_command(args)
    return code, out.getvalue(), err.getvalue()


class Syslog:
    LOG_NOTICE = 5

    def __init__(self):
        self.lines = []

    def openlog(self, *_args, **_kwargs):
        pass

    def syslog(self, _priority, message):
        self.lines.append(message)


def no_network(*_args, **_kwargs):
    raise AssertionError("the budget policy touched the network")


guard.request = no_network
syslog = guard.syslog = Syslog()

# --- reading -------------------------------------------------------------------------------------
shutil.rmtree(ROOT)
os.mkdir(ROOT)
guard.BUDGET_DIRECTORY = os.path.join(ROOT, "absent")
assert guard.read_monthly_budget() is None, "an absent directory is the host fallback"
fresh_directory()
assert guard.read_monthly_budget() is None, "an absent file is the host fallback"

def extras(directory):
    """The writer's lock file, if any: stable, regular, readable by its owner alone; nothing else may remain."""
    others = [name for name in os.listdir(directory) if name != guard.BUDGET_FILENAME]
    assert len(others) <= 1, others
    for name in others:
        info = os.lstat(os.path.join(directory, name))
        assert stat.S_ISREG(info.st_mode) and info.st_mode & 0o777 == 0o600 and info.st_uid == UID, (name, oct(info.st_mode))
        assert name != guard._BUDGET_TEMP, "a temporary file was left behind"
    return others


for mode in (0o644, 0o444):
    fresh_directory("1234\n", mode=mode)
    assert guard.read_monthly_budget() == 1234, oct(mode)
fresh_directory("7")
assert guard.read_monthly_budget() == 7, "no trailing newline"
fresh_directory("9999999\n")
assert guard.read_monthly_budget() == 9999999

for mode in (0o664, 0o666, 0o646, 0o620, 0o602, 0o600, 0o640, 0o400):
    fresh_directory("200\n", mode=mode)
    rejected(f"file mode {oct(mode)} writable by others")
for directory_mode in (0o777, 0o775, 0o757):
    fresh_directory("200\n", directory_mode=directory_mode)
    rejected(f"directory mode {oct(directory_mode)} writable by others")

for text in ("", "\n", "0\n", "-5\n", "12.5\n", "1e3\n", "abc\n", "12345678\n", " 5\n", "5 \n", "5\n\n", "05\n", "+5\n", "5\r\n", "5" + "0" * 70 + "\n"):
    fresh_directory(text)
    rejected(f"content {text[:12]!r}")
fresh_directory(b"\xff\xfe\n")
rejected("non-ASCII content")

directory = fresh_directory()
with open(os.path.join(directory, "target"), "w") as target:
    target.write("500\n")
os.symlink("target", policy_file())
rejected("symlinked policy file")
directory = fresh_directory()
os.mkdir(policy_file())
rejected("directory as policy file")
directory = fresh_directory()
os.mkfifo(policy_file())
rejected("fifo as policy file")

fresh_directory("200\n")
guard.BUDGET_OWNER_UID = UID + 1
rejected("file and directory owned by another uid")
guard.BUDGET_OWNER_UID = UID

real = fresh_directory("200\n")
link = os.path.join(ROOT, "link")
os.symlink(real, link)
guard.BUDGET_DIRECTORY = link
rejected("symlinked directory")

# --- the command: show, set, refusals --------------------------------------------------------------------
guard.MONTH_CAP = 123.0
fresh_directory()
code, out, err = run_command(["show"])
assert code == 0 and "123 EUR" in out and "host fallback" in out and not err, (code, out, err)
fresh_directory("250\n")
code, out, err = run_command(["show"])
assert code == 0 and "250 EUR" in out and "host fallback" not in out, (code, out, err)
fresh_directory("junk\n")
code, out, err = run_command(["show"])
assert code == 1 and "INVALID" in err and not out, (code, out, err)

for args in ([], ["bogus"], ["set"], ["show", "x"], ["set", "1", "2"]):
    code, out, err = run_command(args)
    assert code == 2 and "usage" in err, (args, code, err)

# Unprivileged: refused before any write, whatever the value.
directory = fresh_directory("250\n")
before = snapshot(directory)
with mock.patch.object(os, "geteuid", return_value=1000):
    code, out, err = run_command(["set", "300"])
assert code == 1 and "root" in err and not out, (code, out, err)
assert snapshot(directory) == before and not syslog.lines, "an unprivileged set wrote or logged"
directory = fresh_directory()
with mock.patch.object(os, "geteuid", return_value=1000):
    code, _, _ = run_command(["set", "300"])
assert code == 1 and not os.listdir(directory), "an unprivileged set created a file"

with mock.patch.object(os, "geteuid", return_value=0):
    # Invalid values: nothing written, nothing logged.
    directory = fresh_directory("250\n")
    before = snapshot(directory)
    for value in ("0", "-1", "abc", "1.5", "", "12345678", "01", "1e3", " 5"):
        code, _, err = run_command(["set", value])
        assert code == 2 and err, (value, code)
    assert snapshot(directory) == before and not syslog.lines

    # Missing file: created 0644 holding the integer; the old cap is "host fallback" in the log.
    directory = fresh_directory()
    code, out, err = run_command(["set", "250"])
    assert code == 0 and not err, (code, out, err)
    assert open(policy_file()).read() == "250\n"
    info = os.stat(policy_file())
    assert info.st_mode & 0o777 == 0o644 and info.st_uid == UID, oct(info.st_mode)
    assert extras(directory) is not None, "a temporary file was left behind"
    assert guard.read_monthly_budget() == 250
    assert syslog.lines == ["monthly cap changed: 123 EUR (host default) -> 250 EUR"], syslog.lines

    # Atomic replacement: a reader holding the old file keeps a complete old value; the path is never partial.
    with open(policy_file(), "rb") as reader:
        old_inode = os.fstat(reader.fileno()).st_ino
        code, _, _ = run_command(["set", "300"])
        assert code == 0
        assert reader.read() == b"250\n", "the old file changed in place"
    assert os.stat(policy_file()).st_ino != old_inode, "the file was rewritten in place, not replaced"
    assert open(policy_file()).read() == "300\n" and extras(directory) is not None
    assert syslog.lines[-1] == "monthly cap changed: 250 EUR -> 300 EUR", syslog.lines

    # Same value: no write, no log.
    logged = len(syslog.lines)
    inode = os.stat(policy_file()).st_ino
    code, out, _ = run_command(["set", "300"])
    assert code == 0 and "unchanged" in out and os.stat(policy_file()).st_ino == inode and len(syslog.lines) == logged

    # A same-value set repairs a policy file the guard could not read (0600, 0640).
    for mode in (0o600, 0o640):
        directory = fresh_directory("300\n", mode=mode)
        rejected(f"file mode {oct(mode)} not readable by others")
        code, _, _ = run_command(["set", "300"])
        assert code == 0 and guard.read_monthly_budget() == 300, oct(mode)
        assert os.stat(policy_file()).st_mode & 0o777 == 0o644, "the repaired file is not 0644"
        extras(directory)

    # A stale or hostile temporary entry never receives the write.
    directory = fresh_directory("250\n")
    victim = os.path.join(ROOT, "victim")
    with open(victim, "w") as target:
        target.write("keep\n")
    os.symlink(victim, os.path.join(directory, guard._BUDGET_TEMP))
    code, _, _ = run_command(["set", "400"])
    assert code == 0 and open(victim).read() == "keep\n" and open(policy_file()).read() == "400\n"
    assert extras(directory) is not None

    # An invalid present file is repaired by a set.
    fresh_directory("junk\n")
    code, _, _ = run_command(["set", "500"])
    assert code == 0 and guard.read_monthly_budget() == 500
    assert syslog.lines[-1] == "monthly cap changed: invalid -> 500 EUR", syslog.lines

    # A missing directory (Nix creates it) is an error, never created by the command.
    guard.BUDGET_DIRECTORY = os.path.join(ROOT, "missing-directory")
    code, _, err = run_command(["set", "500"])
    assert code == 1 and "missing" in err and not os.path.exists(guard.BUDGET_DIRECTORY)

    # An unsafe directory or foreign owner is refused.
    directory = fresh_directory("200\n", directory_mode=0o777)
    code, _, _ = run_command(["set", "500"])
    assert code == 1 and open(policy_file()).read() == "200\n"

# The entry point routes `budget` to the command and never reads Clever.
directory = fresh_directory("250\n")
guard.Clever = no_network
sys.argv = ["guard", "budget", "show"]
out = io.StringIO()
with contextlib.redirect_stdout(out):
    assert guard.main() == 0
assert "250 EUR" in out.getvalue()
sys.argv = ["guard"]

# --- tick -----------------------------------------------------------------------------------------------
NOW = int(datetime(2026, 6, 15, 12, tzinfo=guard.PARIS).timestamp() * 1000)
HOURLY = 0.01  # today 12 h = 0,12 EUR, the month 348 h = 3,48 EUR


class FakeClever:
    def __init__(self):
        self.stopped = []

    def pool(self):
        gone = "myparcelle-ci-1" in self.stopped
        flavour = {"name": "XS"}
        return [{
            "id": "a1", "name": "myparcelle-ci-1", "state": "SHOULD_BE_DOWN" if gone else "SHOULD_BE_UP",
            "instance": {"minInstances": 1, "maxInstances": 1, "minFlavor": flavour, "maxFlavor": flavour},
            "instances": [] if gone else [{"id": "i1", "creationDate": NOW - 60_000, "state": "UP"}],
        }]

    def stop(self, app):
        self.stopped.append(app["name"])

    def uptimes(self, _ids, start, end):
        return {"i1": ("a1", "XS", end - start)}


class World:
    """The recorded world around one guard run."""

    def __init__(self, latched_controller=False):
        self.clever = FakeClever()
        self.posts, self.routes = [], []
        counter[0] += 1
        self.latch = os.path.join(ROOT, f"latch-{counter[0]}")
        self.patches = [
            mock.patch.object(guard, "Clever", lambda: self.clever),
            mock.patch.object(guard, "prices", lambda: {"XS": HOURLY}),
            mock.patch.object(guard, "post", self.posts.append),
            mock.patch.object(guard, "route_to_dev_01", lambda: self.routes.append(1) or True),
            mock.patch.object(guard, "controller_active", lambda: latched_controller),
            mock.patch.object(guard, "LATCH", self.latch),
            mock.patch.object(guard, "REPORT", False),
        ]

    def __enter__(self):
        for patch in self.patches:
            patch.start()
        return self

    def __exit__(self, *_exc):
        for patch in self.patches:
            patch.stop()

    def tick(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return guard.tick({}, NOW)

    def latched(self):
        return os.path.exists(self.latch)


def untouched(world):
    assert not world.latched() and not world.clever.stopped and not world.routes and not world.posts, (
        world.latched(), world.clever.stopped, world.routes, world.posts)


guard.MONTH_CAP = 1000.0
guard.DAY_CAP = 25.0

# Missing policy: the host fallback applies.
fresh_directory()
with World() as world:
    world.tick()
    untouched(world)
guard.MONTH_CAP = 3.0
with World() as world:
    world.tick()
    assert world.latched() and world.clever.stopped == ["myparcelle-ci-1"] and world.routes
    reason = json.load(open(world.latch))["reason"]
    assert "mois" in reason, reason
    assert world.posts and "mois" in world.posts[0]

# The live policy overrides the fallback both ways.
fresh_directory("3\n")
guard.MONTH_CAP = 1000.0
with World() as world:
    world.tick()
    assert world.latched() and world.clever.stopped == ["myparcelle-ci-1"], "over the live cap: kill switch"
    assert "3,48" in json.load(open(world.latch))["reason"] and "3,00" in json.load(open(world.latch))["reason"]
fresh_directory("100000\n")
guard.MONTH_CAP = 3.0
with World() as world:
    world.tick()
    untouched(world)

# The live policy leaves the day cap alone.
guard.DAY_CAP = 0.05
fresh_directory("100000\n")
with World() as world:
    world.tick()
    assert world.latched() and "jour" in json.load(open(world.latch))["reason"]
guard.DAY_CAP = 25.0

# A malformed present policy fails closed: latch, fallback cap named, machines stopped, CI routed away, alert.
guard.MONTH_CAP = 1000.0
directory = fresh_directory("junk\n")
policy_before = snapshot(directory)
with World() as world:
    world.tick()
    assert world.latched() and world.clever.stopped == ["myparcelle-ci-1"] and world.routes
    reason = json.load(open(world.latch))["reason"]
    assert "plafond mensuel invalide" in reason, reason
    assert world.posts and "plafond mensuel invalide" in world.posts[0], world.posts
    assert "sudo rm" not in world.posts[0], "the alert must not tell to clear the latch blindly"
    assert snapshot(directory) == policy_before, "the policy file changed"
    # Repairing the policy never clears the latch, and a latched tick keeps everything stopped and routed away.
    os.unlink(policy_file())
    with open(policy_file(), "w") as target:
        target.write("100000\n")
    os.chmod(policy_file(), 0o644)
    world.clever.stopped.clear()
    world.routes.clear()
    world.tick()
    assert world.latched(), "a repaired policy cleared the latch"
    assert world.clever.stopped == ["myparcelle-ci-1"] and world.routes

# Invalid policy on an already latched guard: no second latch, still stopped and routed away.
fresh_directory("0\n")
with World(latched_controller=True) as world:
    with open(world.latch, "w") as target:
        target.write("{}\n")
    world.tick()
    assert world.clever.stopped == ["myparcelle-ci-1"] and world.routes
    assert json.load(open(world.latch)) == {}, "the existing latch was rewritten"
    assert len(world.posts) == 1 and "à la main" in world.posts[0], world.posts

# A malformed policy with a failing provider (Clever() itself raises, before any cloud read): the local
# latch and the CI_RUNS_ON fallback still happen.
fresh_directory("junk\n")
with World() as world:
    def broken_clever():
        raise RuntimeError("application configuration error")

    with mock.patch.object(guard, "Clever", broken_clever), mock.patch.object(guard, "STATE", os.path.join(ROOT, "provider-state.json")):
        with contextlib.redirect_stdout(io.StringIO()):
            guard.main()
    assert world.latched() and world.routes, (world.latched(), world.routes)
    assert "plafond mensuel invalide" in json.load(open(world.latch))["reason"]

# Report mode: reads only, whatever the policy says.
for content in ("3\n", None):
    directory = fresh_directory(content)
    before = snapshot(directory)
    guard.MONTH_CAP = 3.0 if content is None else 1000.0
    with World() as world:
        with mock.patch.object(guard, "REPORT", True):
            with contextlib.redirect_stdout(io.StringIO()) as shown:
                assert guard.tick({}, NOW) is None
        untouched(world)
        assert snapshot(directory) == before
        assert "myparcelle-ci-1" in shown.getvalue()
directory = fresh_directory("junk\n")
before = snapshot(directory)
guard.MONTH_CAP = 1000.0
with World() as world:
    with mock.patch.object(guard, "REPORT", True):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                guard.tick({}, NOW)
        except guard.BudgetPolicyError:
            pass
        else:
            raise AssertionError("--report succeeded on an invalid policy")
    untouched(world)
    assert snapshot(directory) == before
    # ... and main() turns that into a failing exit code without writing state or a latch.
    with mock.patch.object(guard, "REPORT", True), mock.patch.object(guard, "STATE", os.path.join(ROOT, "state.json")):
        with contextlib.redirect_stdout(io.StringIO()):
            assert guard.main() == 1
    untouched(world)
    assert not os.path.exists(os.path.join(ROOT, "state.json"))

shutil.rmtree(ROOT)
print("budget policy: ok")
