"""Exercise generation effects without activating a host or contacting a service manager."""

import json
from pathlib import Path
import shutil
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


def report(current, candidate, activation="home-manager", scope=None, extra=()):
    argv = [
        analyzer,
        "--host", "fixture",
        "--activation", activation,
        "--current", str(current),
        "--candidate", str(candidate),
    ]
    if activation == "home-manager":
        argv.extend(["--user", "fixture"])
    if scope is not None:
        argv.extend(["--scope", scope])
    argv.extend(extra)
    result = subprocess.run(argv, capture_output=True, text=True, check=True)
    value = json.loads(result.stdout)
    assert value["schemaVersion"] == 1, value
    return value


with tempfile.TemporaryDirectory(prefix="disruption-masks-") as directory:
    root = Path(directory)
    old = root / "old"
    new = root / "new"
    relative = "home-files/.config/systemd/user/console-getty.service"
    for generation in (old, new):
        path = generation / relative
        path.parent.mkdir(parents=True)
        path.symlink_to("/dev/null")
    unchanged = report(old, new)
    assert unchanged["status"] == "safe", unchanged
    assert not unchanged["effects"], unchanged
    (old / relative).unlink()
    put(old, relative, unit("/bin/shell", owner=True))
    wanted = (old / relative).parent / "default.target.wants"
    wanted.mkdir()
    (wanted / "console-getty.service").symlink_to("../console-getty.service")
    masked = report(old, new)
    assert masked["status"] == "blocked", masked
    assert any(effect["action"] == "stop" and effect["protected"]
               for effect in masked["effects"]), masked
    unmasked = report(new, old)
    assert any(effect["action"] == "start" for effect in unmasked["effects"]), unmasked
    (new / relative).unlink()
    (new / relative).symlink_to("/nonexistent-disruption-fixture")
    assert report(old, new)["status"] == "unknown"


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

    # sd-switch reads the running unit's refusal flag, not a newly installed flag.
    new_refusal = root / "new-refusal-generation"
    put(new_refusal, agent, unit(new_exe).replace(
        "[Service]", "RefuseManualStop=true\n[Service]"))
    assert report(current, new_refusal)["status"] == "blocked"

    # Retaining a combined process while declaring its slot replaceable is unsafe on
    # the NEXT activation, even though this activation would keep the old process.
    guarded = root / "guarded-generation"
    split_generation = root / "split-generation"
    put(guarded, agent, unit(old_exe, owner=True).replace(
        "[Service]", "X-SwitchMethod=keep-old\nRefuseManualStop=true\n[Service]"))
    put(split_generation, agent, unit(new_exe, owner=False))
    assert report(guarded, split_generation)["status"] == "blocked"
    manager = root / "systemctl"
    def manager_answer(body):
        manager.write_text(f"#!{sys.executable}\n{body}\n")
        manager.chmod(0o755)
    runtime = ("--runtime", "--systemctl", str(manager), "--manager-user", "fixture")
    manager_answer("print('LoadState=loaded\\nActiveState=active')")
    assert report(guarded, split_generation, extra=runtime)["status"] == "blocked"
    manager_answer("print('LoadState=loaded\\nActiveState=inactive')")
    stopped = report(guarded, split_generation, extra=runtime)
    assert stopped["status"] == "safe", stopped
    assert any(effect["action"] == "start" for effect in stopped["effects"]), stopped
    manager_answer("raise SystemExit(1)")
    assert report(guarded, split_generation, extra=runtime)["status"] == "unknown"
    manager_answer("print('LoadState=loaded\\nActiveState=active')")
    returned = report(guarded, split_generation, extra=runtime)
    assert returned["status"] == "blocked", returned
    assert returned["fingerprint"] != stopped["fingerprint"]

    # A live definition cannot contradict the deployed role during direct service control.
    mutation = report(guarded, guarded, extra=(
        *runtime, "--mutate", "restart", "--service", "user:manifold-agent.service",
        "--live", str(split_generation / agent)))
    assert mutation["status"] == "unknown", mutation

    # NixOS switches global user units in every live manager, not only ours.
    global_old = root / "global-old-system"
    global_new = root / "global-new-system"
    for generation, executable in ((global_old, old_exe), (global_new, new_exe)):
        put(generation, "etc/systemd/system/placeholder", "")
        put(generation, "etc/systemd/user/manifold-agent.service", unit(executable, owner=True))
    run_user = root / "run-user"
    (run_user / "0").mkdir(parents=True)
    (run_user / "123456").mkdir()
    global_runtime = (
        *runtime, "--manager-user", "root", "--manager-uid", "0",
        "--run-user-dir", str(run_user),
    )
    manager_answer(
        "import sys\n"
        "state = 'active' if any(a.startswith('--machine=') for a in sys.argv) else 'inactive'\n"
        "print('LoadState=loaded\\nActiveState=' + state)"
    )
    assert report(global_old, global_new, "nixos", extra=global_runtime)["status"] == "blocked"
    manager_answer("print('LoadState=loaded\\nActiveState=inactive')")
    assert report(global_old, global_new, "nixos", extra=global_runtime)["status"] == "safe"
    manager_answer(
        "import sys\n"
        "if any(a.startswith('--machine=') for a in sys.argv): raise SystemExit(1)\n"
        "print('LoadState=loaded\\nActiveState=inactive')"
    )
    assert report(global_old, global_new, "nixos", extra=global_runtime)["status"] == "unknown"
    assert report(global_old, global_new, "nixos", extra=(
        *global_runtime, "--manager-user", "fixture", "--manager-uid", "123456",
    ))["status"] == "unknown"

    # Home Manager folds config-side drop-ins even when the base file is unchanged.
    dropin = root / "dropin-generation"
    put(dropin, agent, unit(old_exe, "%H"))
    put(dropin, agent + ".d/override.conf", "[Service]\nEnvironment=EXTRA=changed\n")
    assert report(current, dropin)["status"] == "blocked"

    # An unstatable ancestor is not an absent unit tree (ELOOP also fails under root).
    inaccessible = root / "inaccessible-generation"
    put(inaccessible, "home-files/.config/systemd/placeholder", "")
    (inaccessible / units).symlink_to("user")
    assert report(inaccessible, candidate)["status"] == "unknown"

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

    # sshd's listener restart can preserve sessions, but removal still closes access.
    ssh = "etc/systemd/system/sshd.service"
    for system, executable in ((old_system, "old"), (new_system, "new")):
        put(system, ssh, f"[Service]\nKillMode=process\nExecStart=/fixture/{executable}-sshd\n")
    assert report(old_system, new_system, "nixos")["status"] == "safe"
    put(new_system, ssh, "[Service]\nKillMode=control-group\nExecStart=/fixture/new-sshd\n")
    assert report(old_system, new_system, "nixos")["status"] == "blocked"
    (new_system / ssh).unlink()
    assert report(old_system, new_system, "nixos")["status"] == "blocked"
    (old_system / ssh).unlink()
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
    next_candidate = root / "another-home-manager-generation"
    shutil.copytree(candidate, next_candidate)
    put(next_candidate, units + "worker.service", unit("/nix/store/another-worker/bin/worker"))
    second = report(current, next_candidate)
    assert first["fingerprint"] != second["fingerprint"], (first, second)

print("disruption contract: same-version restart, ownership boundary, embedded units, scope, unknown state, and fingerprint passed")
