"""Retain the dedicated dev slice independently of replaceable Docker scopes."""

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import stat
import sys
import time


CONTROLLERS = {"cpu", "memory", "pids"}
SLICE = "manifold-dev-isolates.slice"
UNIT = "manifold-dev-isolates.service"
CGROUP_FS = Path("/sys/fs/cgroup")


def runtime_directory():
    directory = Path(f"/run/user/{os.getuid()}/manifold-dev-isolates")
    metadata = directory.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise RuntimeError("runtime directory is not owned by this user")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise RuntimeError("runtime directory must have mode 0700")
    return directory


def unit_directory(control_group):
    relative = Path(control_group.removeprefix("/"))
    if ".." in relative.parts or relative.name != UNIT or relative.parent.name != SLICE:
        raise RuntimeError("expected the dedicated user unit inside its dedicated slice")
    directory = CGROUP_FS / relative
    if directory.resolve(strict=True) != directory:
        raise RuntimeError("unit cgroup must not traverse symlinks")
    return directory


def current_unit_directory():
    memberships = Path("/proc/self/cgroup").read_text().splitlines()
    unified = [line[3:] for line in memberships if line.startswith("0::")]
    if len(unified) != 1:
        raise RuntimeError("a unified cgroup v2 membership is required")
    return unit_directory(unified[0])


def require_controllers(directory, filename):
    if not CONTROLLERS <= set((directory / filename).read_text().split()):
        raise RuntimeError(f"{directory}/{filename} lacks cpu, memory or pids")


def guests_absent(root):
    # Include empty/starting guest directories. Unknown is not empty. The only
    # non-guest child is our own service, whose keeper holds the delegation.
    try:
        return not any(entry.is_dir() and entry.name != UNIT for entry in root.iterdir())
    except OSError:
        return False


def status(control_group):
    owner = unit_directory(control_group)
    root = owner.parent
    link = runtime_directory() / "cgroup"
    if not link.is_symlink() or link.resolve(strict=True) != root:
        raise RuntimeError("runtime cgroup link does not name the dedicated slice")
    for directory in (root, owner):
        if (directory / "cgroup.type").read_text().strip() != "domain":
            raise RuntimeError(f"{directory} is not a domain cgroup")
        if (directory / "cgroup.procs").read_text().strip():
            raise RuntimeError(f"{directory} must have no direct members")
        require_controllers(directory, "cgroup.subtree_control")
    grant = json.loads((runtime_directory() / "delegation.json").read_text())
    for name in ("", "cgroup.procs", "cgroup.subtree_control"):
        metadata = (root / name).stat()
        expected_mode = 0o770 if name == "" else 0o660
        if (metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode)) != (
            grant["hostUid"], os.getgid(), expected_mode
        ):
            raise RuntimeError("dedicated slice ownership does not match its scoped grant")
    return {"ready": True, "path": str(link), "controlGroup": control_group,
            "controllers": sorted(CONTROLLERS), "guestsAbsent": guests_absent(root),
            "mapping": grant}


def prepare(owner, runtime):
    root = owner.parent
    require_controllers(root, "cgroup.subtree_control")
    require_controllers(owner, "cgroup.controllers")
    if (owner / "cgroup.procs").read_text().split() != [str(os.getpid())]:
        raise RuntimeError("unit root has unexpected members; refusing to move other processes")
    keeper = owner / "keeper"
    keeper.mkdir(exist_ok=True)
    (keeper / "cgroup.procs").write_text(str(os.getpid()))
    (owner / "cgroup.subtree_control").write_text("+cpu +memory +pids")
    link = runtime / "cgroup"
    if link.is_symlink():
        if os.readlink(link) != str(root):
            raise RuntimeError("existing runtime link names a different owner; refusing replacement")
    elif link.exists():
        raise RuntimeError("runtime cgroup path exists but is not the managed symlink")
    else:
        link.symlink_to(root)
    return root


def notify_ready():
    address = os.environ["NOTIFY_SOCKET"]
    if address.startswith("@"):
        address = "\0" + address[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notification:
        notification.connect(address)
        notification.sendall(b"READY=1")


def retain(root):
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    notify_ready()
    while True:
        if stopping and guests_absent(root):
            return
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("hold")
    inspect = commands.add_parser("status")
    inspect.add_argument("--control-group", required=True)
    args = parser.parse_args()
    if args.command == "status":
        try:
            result = status(args.control_group)
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            print(json.dumps({"ready": False, "reason": str(error)}))
            return 1
        print(json.dumps(result))
        return 0
    owner = current_unit_directory()
    root = prepare(owner, runtime_directory())
    retain(root)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"manifold-dev-isolates: {error}", file=sys.stderr)
        sys.exit(1)
