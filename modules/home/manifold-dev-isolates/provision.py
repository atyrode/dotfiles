"""Root-only, fixed dev slice grant; never changes an ancestor or guest cgroup."""

import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
import sys


USERNAME = "@username@"
SYSTEMCTL = "@systemctl@"
SLICE = "manifold-dev-isolates.slice"
UNIT = "manifold-dev-isolates.service"


def subordinate_id(filename, user, container_id):
    allocations = []
    for line in Path(filename).read_text().splitlines():
        fields = line.split(":")
        if len(fields) == 3 and fields[0] in (user.pw_name, str(user.pw_uid)):
            allocations.append((int(fields[1]), int(fields[2])))
    if len(allocations) != 1 or allocations[0][1] < container_id:
        raise RuntimeError(f"{filename}: expected one declared allocation covering container ID 1000")
    start, count = allocations[0]
    if start <= 0 or count <= 0:
        raise RuntimeError("invalid subordinate allocation")
    return start + container_id - 1, start, count


def manager_property(user, unit, property_name):
    return subprocess.check_output(
        [SYSTEMCTL, "--user", f"--machine={user.pw_name}@.host", "show", "--value",
         f"--property={property_name}", unit], text=True, timeout=10
    ).strip()


def verify_docker_mapping(user, uid_allocation, gid_allocation):
    main_pid = int(manager_property(user, "docker.service", "MainPID"))
    if main_pid <= 1:
        raise RuntimeError("the managed rootless Docker service must be running")
    expected_uid = [(0, user.pw_uid, 1), (1, uid_allocation[1], uid_allocation[2])]
    expected_gid = [(0, user.pw_gid, 1), (1, gid_allocation[1], gid_allocation[2])]
    pending = [main_pid]
    visited = set()
    # RootlessKit's manager can be outside its child's user namespace. Inspect
    # only descendants of Docker's authoritative MainPID; never scan host PIDs.
    while pending and len(visited) < 4096:
        pid = pending.pop()
        if pid in visited:
            continue
        visited.add(pid)
        process = Path(f"/proc/{pid}")
        try:
            uid_map = [tuple(map(int, line.split())) for line in (process / "uid_map").read_text().splitlines()]
            gid_map = [tuple(map(int, line.split())) for line in (process / "gid_map").read_text().splitlines()]
            if uid_map == expected_uid and gid_map == expected_gid:
                return
            pending.extend(map(int, (process / f"task/{pid}/children").read_text().split()))
        except FileNotFoundError:
            continue
    raise RuntimeError("managed Docker's live UID/GID maps do not match the declared subordinate allocations")


def main():
    if os.geteuid() != 0 or len(sys.argv) != 1:
        raise RuntimeError("run the fixed no-argument provisioner through atyrode runtime provision")
    user = pwd.getpwnam(USERNAME)
    if user.pw_uid != 1000:
        raise RuntimeError("this dev-only runtime contract requires the declared UID 1000 account")
    uid_allocation = subordinate_id("/etc/subuid", user, 1000)
    gid_allocation = subordinate_id("/etc/subgid", user, 1000)
    verify_docker_mapping(user, uid_allocation, gid_allocation)
    expected = (f"/user.slice/user-{user.pw_uid}.slice/user@{user.pw_uid}.service/"
                f"manifold.slice/manifold-dev.slice/{SLICE}")
    control_group = manager_property(user, UNIT, "ControlGroup")
    if control_group != f"{expected}/{UNIT}":
        raise RuntimeError("holder is not in the whitelisted dev slice")
    if manager_property(user, UNIT, "ActiveState") != "active":
        raise RuntimeError("the managed delegation holder must be active")
    root = Path("/sys/fs/cgroup" + expected)
    if root.resolve(strict=True) != root:
        raise RuntimeError("the dedicated slice must not traverse symlinks")
    runtime = Path(f"/run/user/{user.pw_uid}/manifold-dev-isolates")
    if runtime.resolve(strict=True) != runtime:
        raise RuntimeError("runtime directory must not traverse symlinks")
    metadata = runtime.stat()
    if metadata.st_uid != user.pw_uid or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise RuntimeError("runtime directory ownership or mode is incorrect")
    grant = {"containerUid": 1000, "containerGid": 1000,
             "hostUid": uid_allocation[0], "hostGid": gid_allocation[0],
             "managerGid": user.pw_gid, "slice": SLICE}
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    runtime_fd = os.open(runtime, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptors = [root_fd]
    try:
        for name in ("cgroup.procs", "cgroup.subtree_control"):
            descriptors.append(os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root_fd))
        expected_modes = (0o770, 0o660, 0o660)
        correct = all(
            (os.fstat(fd).st_uid, os.fstat(fd).st_gid, stat.S_IMODE(os.fstat(fd).st_mode))
            == (grant["hostUid"], user.pw_gid, mode)
            for fd, mode in zip(descriptors, expected_modes)
        )
        try:
            record_fd = os.open("delegation.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=runtime_fd)
        except FileNotFoundError:
            record = None
        else:
            with os.fdopen(record_fd) as record_file:
                record = json.load(record_file)
        if correct and record == grant:
            print("dedicated slice grant already converged; no guest or owner was changed")
            return
        # This is a provisioning operation, not a repair of an incumbent tree.
        # Even an empty Docker scope/guest directory blocks ownership mutation.
        children = [entry.name for entry in root.iterdir() if entry.is_dir()]
        if children != [UNIT] or (root / "cgroup.procs").read_text().strip():
            raise RuntimeError("dedicated slice has incumbent children; refusing ownership changes")
        if record is not None:
            raise RuntimeError("existing grant differs; explicit drained maintenance is required")
        for directory in (root, root / UNIT):
            if not {"cpu", "memory", "pids"} <= set((directory / "cgroup.subtree_control").read_text().split()):
                raise RuntimeError("holder has not enabled all required delegated controllers")
        # Descriptors pin exactly the allowlisted slice and two delegation
        # files; no recursive chown, path from argv, ancestor write or guest edit.
        for fd, mode in zip(descriptors, expected_modes):
            os.fchown(fd, grant["hostUid"], user.pw_gid)
            os.fchmod(fd, mode)
        record_fd = os.open("delegation.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                            0o644, dir_fd=runtime_fd)
        with os.fdopen(record_fd, "w") as record_file:
            json.dump(grant, record_file)
            record_file.write("\n")
        print("granted only the dedicated dev slice to verified container UID 1000")
    finally:
        for fd in descriptors:
            os.close(fd)
        os.close(runtime_fd)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"manifold-dev-isolates-provision: {error}", file=sys.stderr)
        sys.exit(1)
