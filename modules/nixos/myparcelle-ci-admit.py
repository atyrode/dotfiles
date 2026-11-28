"""ci-01's runner admission: keep exactly one idle registered runner, and start the
next one only while the host's live memory still covers a whole job.

Run every few seconds by myparcelle-ci-admit.timer as root. Slots are identical
systemd units (myparcelle-ci-runner-<n>); an idle slot is a started unit whose
runner holds no job, a busy slot has a Runner.Worker process in its cgroup. The
rule, from the design in docs/hosts.md:

    budget = MemAvailable
             - sum over busy slots of max(0, reserve - memory that slot already uses)
             - floor
    start the lowest free slot when no slot is idle and budget >= reserve

Subtracting only each running job's *unspent* reserve keeps memory it has already
taken (and MemAvailable already lost) from being counted twice. Anything the
launcher cannot read or parse starts nothing: a slot it cannot classify is never
assumed free, and a fenced slot (quarantine lease present) is never started.
The kernel limit stays separate: each slot's cgroup slice has MemoryMax = reserve,
so a job that outgrows its reservation is killed alone.
"""
import os
import subprocess
import sys
import time

GIB = 1024**3


def decide(mem_available, slots, reserve, floor):
    """Return (slot number or None, reason) for one admission tick.

    `slots` is a list of {"slot": n, "state": s, "used": bytes}; s is one of
    down (startable), cooling (recently started, not yet again), fenced (lease
    held), tearing (stopping), idle (started, no job) or busy (a job runs).
    """
    states = {slot["state"] for slot in slots}
    unknown = states - {"down", "cooling", "fenced", "tearing", "idle", "busy"}
    if unknown:
        raise ValueError(f"unknown slot state(s): {sorted(unknown)}")
    if "idle" in states:
        return None, "an idle runner is already registered"
    unspent = sum(max(0, reserve - slot["used"]) for slot in slots if slot["state"] == "busy")
    budget = mem_available - unspent - floor
    if budget < reserve:
        return None, f"budget {budget // 1048576} MiB < reserve {reserve // 1048576} MiB"
    free = [slot["slot"] for slot in slots if slot["state"] == "down"]
    if not free:
        return None, "no startable slot"
    return min(free), f"budget {budget // 1048576} MiB covers a {reserve // 1048576} MiB reserve"


def read_mem_available(path):
    with open(path, encoding="ascii") as handle:
        for line in handle:
            if line.startswith("MemAvailable:"):
                fields = line.split()
                if len(fields) == 3 and fields[2] == "kB":
                    return int(fields[1]) * 1024
    raise ValueError(f"no MemAvailable in {path}")


def slice_usage(slice_path):
    """(has a Runner.Worker, anon + shmem bytes) of a slot's cgroup subtree; (False, 0) when it has none."""
    if not os.path.isdir(slice_path):
        return False, 0
    worker = False
    for directory, _, files in os.walk(slice_path):
        if "cgroup.procs" not in files:
            continue
        with open(os.path.join(directory, "cgroup.procs"), encoding="ascii") as handle:
            for pid in handle.read().split():
                try:
                    with open(f"/proc/{int(pid)}/comm", encoding="utf-8") as comm:
                        worker = worker or comm.read().strip() == "Runner.Worker"
                except FileNotFoundError:
                    continue
    used = 0
    with open(os.path.join(slice_path, "memory.stat"), encoding="ascii") as handle:
        for line in handle:
            key, _, value = line.partition(" ")
            if key in ("anon", "shmem"):
                used += int(value)
    return worker, used


def unit_state(unit, systemctl):
    out = subprocess.run([systemctl, "show", unit, "--property=ActiveState", "--value"], check=True, capture_output=True, text=True)
    return out.stdout.strip()


def classify(slot, config, now):
    """One slot's state, from the lease directory, systemd and its cgroup."""
    if os.path.exists(os.path.join(config["lease_root"], f"myparcelle-ci-slot-{slot}", "lease")):
        return {"slot": slot, "state": "fenced", "used": 0}
    active = unit_state(f"myparcelle-ci-runner-{slot}.service", config["systemctl"])
    if active == "deactivating":
        return {"slot": slot, "state": "tearing", "used": 0}
    if active in ("active", "activating", "reloading"):
        worker, used = slice_usage(os.path.join(config["slice_root"], f"ciSlot{slot}.slice"))
        return {"slot": slot, "state": "busy" if worker else "idle", "used": used if worker else 0}
    if active not in ("inactive", "failed"):
        raise ValueError(f"slot {slot}: unexpected unit state {active!r}")
    try:
        with open(os.path.join(config["stamp_root"], f"start-{slot}"), encoding="ascii") as handle:
            started = float(handle.read())
    except FileNotFoundError:
        started = 0.0
    if now - started < config["cooldown"]:
        return {"slot": slot, "state": "cooling", "used": 0}
    return {"slot": slot, "state": "down", "used": 0}


def start(slot, config, now):
    os.makedirs(config["stamp_root"], exist_ok=True)
    stamp = os.path.join(config["stamp_root"], f"start-{slot}")
    with open(stamp + ".new", "w", encoding="ascii") as handle:
        handle.write(f"{now}\n")
    os.replace(stamp + ".new", stamp)
    unit = f"myparcelle-ci-runner-{slot}.service"
    subprocess.run([config["systemctl"], "reset-failed", unit], check=False, capture_output=True)
    subprocess.run([config["systemctl"], "start", "--no-block", unit], check=True)


def configuration(environ):
    return {
        "slots": int(environ["ADMIT_SLOTS"]),
        "reserve": int(environ["ADMIT_RESERVE_BYTES"]),
        "floor": int(environ["ADMIT_FLOOR_BYTES"]),
        "cooldown": float(environ.get("ADMIT_COOLDOWN_SECONDS", "20")),
        "meminfo": environ.get("ADMIT_MEMINFO", "/proc/meminfo"),
        "slice_root": environ["ADMIT_SLICE_ROOT"],
        "lease_root": environ.get("ADMIT_LEASE_ROOT", "/var/lib"),
        "stamp_root": environ.get("ADMIT_STAMP_ROOT", "/run/myparcelle-ci-admit"),
        "systemctl": environ.get("ADMIT_SYSTEMCTL", "systemctl"),
    }


def tick(config, now=None):
    """One admission decision; returns the slot started or None. Raises on anything unreadable."""
    now = time.time() if now is None else now
    slots = [classify(number, config, now) for number in range(1, config["slots"] + 1)]
    chosen, reason = decide(read_mem_available(config["meminfo"]), slots, config["reserve"], config["floor"])
    if chosen is not None:
        start(chosen, config, now)
        print(f"myparcelle-ci-admit: started slot {chosen}: {reason}", flush=True)
    return chosen


def main():
    try:
        tick(configuration(os.environ))
    except Exception as error:  # fail closed: a tick that cannot see the host starts nothing
        print(f"myparcelle-ci-admit: refusing to start a runner: {error!r}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
