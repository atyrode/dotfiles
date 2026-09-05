"""Exercise generation effects without activating a host or contacting a service manager."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


analyzer = sys.argv[1]


def unit(executable, machine="dev-01", owner=None):
    marker = "" if owner is None else f"X-Atyrode-SessionOwner={str(owner).lower()}\n"
    return (
        "[Unit]\nDescription=Fixture service\n"
        + marker
        + "[Service]\n"
        + f"ExecStart={executable}\nEnvironment=MANIFOLD_MACHINE_NAME={machine}\n"
        + "Restart=always\n[Install]\nWantedBy=default.target\n"
    )


def put(root, relative, content):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path


def report(current, candidate, activation="home-manager", scope=None):
    argv = [
        analyzer,
        "--host", "fixture",
        "--activation", activation,
        "--current", str(current),
        "--candidate", str(candidate),
    ]
    if scope is not None:
        argv.extend(["--scope", scope])
    result = subprocess.run(argv, capture_output=True, text=True, check=True)
    value = json.loads(result.stdout)
    assert value["schemaVersion"] == 1, value
    return value


with tempfile.TemporaryDirectory(prefix="disruption-contract-") as directory:
    root = Path(directory)
    current = root / "old-home-manager-generation"
    candidate = root / "new-home-manager-generation"
    units = "home-files/.config/systemd/user/"
    agent = units + "manifold-agent.service"
    old_exe = "/nix/store/2nznq6pcv33namwd2w7fc42d2f9kjqxb-manifold-agent-0.6.2/bin/manifold-agent"
    new_exe = "/nix/store/ih8wab1r5zv4ccpary8m38728c2i1sc1-manifold-agent-0.6.2/bin/manifold-agent"
    put(current, agent, unit(old_exe, "%H"))
    put(candidate, agent, unit(new_exe, "dev-01"))
    changed = report(current, candidate)
    assert changed["status"] == "blocked", changed
    assert any(
        effect["service"] == "manifold-agent.service"
        and effect["protected"]
        and effect["action"] in ("restart", "stop")
        for effect in changed["effects"]
    ), changed

    # Merely labelling a replacement as transport cannot remove the incumbent's protection.
    put(candidate, agent, unit(new_exe, owner=False))
    assert report(current, candidate)["status"] == "blocked"

    # Once both generations explicitly separate ownership, updating only transport is safe.
    put(current, agent, unit(old_exe, owner=False))
    host = units + "manifold-terminal-host.service"
    host_exe = "/nix/store/fixed-terminal-host/bin/manifold-terminal-host"
    put(current, host, unit(host_exe, owner=True))
    put(candidate, host, unit(host_exe, owner=True))
    transport = report(current, candidate)
    assert transport["status"] == "safe", transport
    put(candidate, host, unit("/nix/store/replacement-host/bin/manifold-terminal-host", owner=True))
    assert report(current, candidate)["status"] == "blocked"
    (candidate / host).unlink()
    removed = report(current, candidate)
    assert removed["status"] == "blocked", removed
    assert any(
        effect["service"] == "manifold-terminal-host.service"
        and effect["protected"] and effect["action"] == "stop"
        for effect in removed["effects"]
    ), removed
    put(candidate, host, unit(host_exe, owner=True))
    retained = unit(host_exe, owner=True).replace(
        "[Service]", "X-SwitchMethod=keep-old\nRefuseManualStop=true\n[Service]"
    )
    put(current, host, retained)
    put(candidate, host, retained.replace(host_exe, "/nix/store/new-host/bin/manifold-agent"))
    kept = report(current, candidate)
    assert kept["status"] == "safe", kept
    assert any(
        effect["service"] == "manifold-terminal-host.service" and effect["action"] == "keep"
        for effect in kept["effects"]
    ), kept
    put(current, host, unit(host_exe, owner=True))
    put(candidate, host, unit(host_exe, owner=True))

    # A Caddy-only system change must not become a restart of unchanged embedded user units.
    put(candidate, agent, unit(old_exe, owner=False))
    old_system = root / "old-system"
    new_system = root / "new-system"
    for system, home, caddy in ((old_system, current, "old"), (new_system, candidate, "new")):
        put(system, "etc/systemd/system/home-manager-alex.service",
            f"[Service]\nType=oneshot\nExecStart=/fixture/hm-setup-env {home}\nUser=alex\n")
        put(system, "etc/systemd/system/caddy.service",
            f"[Service]\nExecStart=/nix/store/{caddy}-caddy/bin/caddy\n")
    caddy = report(old_system, new_system, "nixos")
    assert caddy["status"] == "safe", caddy
    assert not any(
        effect["service"] in ("manifold-agent.service", "manifold-terminal-host.service")
        and effect["action"] in ("stop", "restart")
        for effect in caddy["effects"]
    ), caddy
    put(candidate, agent, unit(new_exe, owner=True))
    embedded = report(old_system, new_system, "nixos")
    assert embedded["status"] == "blocked", embedded

    # Declared task scope cannot silently authorize a second, otherwise unprotected service.
    put(current, agent, unit(old_exe, owner=False))
    put(candidate, agent, unit(old_exe, owner=False))
    put(current, units + "worker.service", unit("/nix/store/old-worker/bin/worker"))
    put(candidate, units + "worker.service", unit("/nix/store/new-worker/bin/worker"))
    scoped = report(current, candidate, scope="user:manifold-agent.service")
    assert scoped["status"] == "blocked", scoped

    # Missing or unreadable candidate state is not an empty, harmless generation.
    missing = subprocess.run(
        [analyzer, "--host", "fixture", "--activation", "home-manager",
         "--current", str(current), "--candidate", str(root / "missing-generation")],
        capture_output=True, text=True,
    )
    assert missing.returncode != 0 or json.loads(missing.stdout)["status"] == "unknown", missing.stdout
    put(candidate, host, "not a systemd unit\n")
    malformed = report(current, candidate)
    assert malformed["status"] in ("unknown", "blocked"), malformed

    # The read-only preview fingerprint is bound to the exact transition, not a package label.
    put(candidate, host, unit(host_exe, owner=True))
    first = report(current, candidate)
    put(candidate, units + "worker.service", unit("/nix/store/another-worker/bin/worker"))
    second = report(current, candidate)
    assert first["fingerprint"] != second["fingerprint"], (first, second)

print("disruption contract: same-version restart, ownership boundary, embedded units, scope, unknown state, and fingerprint passed")
