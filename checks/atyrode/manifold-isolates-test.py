"""Check owner retention and allocation boundaries without activating a machine."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import types


holder_path, provision_path, analyzer, service_path, slice_path = sys.argv[1:]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


holder = load("holder", holder_path)
provision = load("provision", provision_path)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    allocation = root / "subuid"
    user = types.SimpleNamespace(pw_name="alex", pw_uid=1000)
    allocation.write_text("other:200000:65536\nalex:300000:65536\n")
    assert provision.subordinate_id(allocation, user, 1000)[0] == 300999
    for content in ("alex:300000:999\n", "alex:300000:65536\nalex:400000:65536\n", ""):
        allocation.write_text(content)
        try:
            provision.subordinate_id(allocation, user, 1000)
        except RuntimeError:
            pass
        else:
            raise AssertionError("ambiguous or insufficient allocation was accepted")

    tree = root / "slice"
    tree.mkdir()
    (tree / holder.UNIT).mkdir()
    assert holder.guests_absent(tree)
    guest = tree / "docker-fixture.scope"
    guest.mkdir()
    assert not holder.guests_absent(tree)
    assert not holder.guests_absent(root / "missing")
    notification_path = root / "notify.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notification:
        notification.bind(str(notification_path))
        notification.settimeout(5)
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import importlib.util, pathlib, sys; "
             "s = importlib.util.spec_from_file_location('holder', sys.argv[1]); "
             "m = importlib.util.module_from_spec(s); s.loader.exec_module(m); "
             "m.retain(pathlib.Path(sys.argv[2]))", holder_path, str(tree)],
            env={**os.environ, "NOTIFY_SOCKET": str(notification_path)},
        )
        try:
            assert notification.recv(256) == b"READY=1"
            child.send_signal(signal.SIGTERM)
            try:
                child.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("TERM released the owner while a guest scope existed")
            assert guest.is_dir(), "retention must not delete guest cgroups"
            guest.rmdir()
            assert child.wait(timeout=3) == 0
            assert (tree / holder.UNIT).is_dir(), "holder must never recursively clean cgroups"
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()

    # Use the actual rendered units: receiver/holder changes must retain both
    # owner definitions, while direct protected-service mutation must refuse.
    old, new = root / "old", root / "new"
    unit_dir = "home-files/.config/systemd/user"
    for generation in (old, new):
        (generation / unit_dir).mkdir(parents=True)
        for name, source in ((holder.UNIT, service_path), (holder.SLICE, slice_path)):
            text = Path(source).read_text()
            if generation == new:
                text = text.replace("Description=", "Description=Updated ", 1)
            (generation / unit_dir / name).write_text(text)
    base = [analyzer, "--host", "dev-01", "--activation", "home-manager",
            "--user", "alex", "--current", str(old)]
    report = json.loads(subprocess.check_output(base + ["--candidate", str(new)], text=True))
    assert report["status"] == "safe", report
    assert {effect["service"] for effect in report["effects"]
            if effect["action"] == "keep" and effect["protected"]} == {holder.UNIT, holder.SLICE}, report
    for unit in (holder.UNIT, holder.SLICE):
        report = json.loads(subprocess.check_output(
            base + ["--mutate", "restart", "--service", f"user:{unit}"], text=True
        ))
        assert report["status"] == "blocked", report

print("dev sandbox allocation, TERM retention and actual-unit disruption cases passed")
