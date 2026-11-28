#!/usr/bin/env python3
"""Exercise ci-01's runner admission offline: the decision table, the tick against
fixture host state, and a stress run with more queued jobs than memory fits.

argv: path of myparcelle-ci-admit.py. The launcher's own functions run; systemd,
/proc/meminfo, the slot cgroups and the quarantine leases are fixtures.
"""
import importlib.util
import os
import random
import shutil
import stat
import subprocess
import sys
import tempfile
import time

PATH = sys.argv[1]
spec = importlib.util.spec_from_file_location("admit", PATH)
admit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admit)

GIB = 1024**3
RESERVE = 6 * GIB
FLOOR = 3 * GIB


def slot(number, state, used=0):
    return {"slot": number, "state": state, "used": used}


# --- decision table -------------------------------------------------------
def check(label, got, want):
    assert got == want, f"{label}: got {got!r}, want {want!r}"


def chosen(mem, slots):
    return admit.decide(mem, slots, RESERVE, FLOOR)[0]


down = [slot(n, "down") for n in range(1, 5)]
check("empty host starts slot 1", chosen(30 * GIB, down), 1)
check("an idle runner blocks every start", chosen(30 * GIB, [slot(1, "idle")] + down[1:]), None)
check("a starting runner is idle too", chosen(30 * GIB, [slot(1, "idle"), slot(2, "busy", 1 * GIB)] + down[2:]), None)
check("lowest free slot", chosen(30 * GIB, [slot(1, "busy", 5 * GIB)] + down[1:]), 2)
# budget = mem - unspent - floor; one busy slot with 1 GiB used leaves 5 GiB unspent.
check("exactly enough", chosen(RESERVE + FLOOR + 5 * GIB, [slot(1, "busy", 1 * GIB)] + down[1:]), 2)
check("one byte short", chosen(RESERVE + FLOOR + 5 * GIB - 1, [slot(1, "busy", 1 * GIB)] + down[1:]), None)
check("a job past its reserve has no unspent headroom", chosen(RESERVE + FLOOR, [slot(1, "busy", 9 * GIB)] + down[1:]), 2)
check("a fenced slot is skipped", chosen(30 * GIB, [slot(1, "fenced")] + down[1:]), 2)
check("every slot fenced starts nothing", chosen(30 * GIB, [slot(n, "fenced") for n in range(1, 5)]), None)
check("a cooling slot is skipped", chosen(30 * GIB, [slot(1, "cooling")] + down[1:]), 2)
check("a tearing slot is neither idle nor free", chosen(30 * GIB, [slot(1, "tearing")] + down[1:]), 2)
check("all slots busy", chosen(30 * GIB, [slot(n, "busy", RESERVE) for n in range(1, 5)]), None)
try:
    chosen(30 * GIB, [slot(1, "bogus")])
except ValueError:
    pass
else:
    raise AssertionError("an unknown state must raise, not start anything")

# --- the tick against fixture host state -----------------------------------
ROOT = tempfile.mkdtemp(prefix="admit-check-")
BIN = os.path.join(ROOT, "bin")
UNITS = os.path.join(ROOT, "units")
os.makedirs(BIN)
os.makedirs(UNITS)
with open(os.path.join(BIN, "systemctl"), "w", encoding="ascii") as handle:
    handle.write(
        f"""#!/bin/sh
case "$1" in
  show) cat "{UNITS}/$2" 2>/dev/null || echo inactive ;;
  start) echo active > "{UNITS}/$3"; echo "$3" >> "{ROOT}/started" ;;
  reset-failed) : ;;
esac
"""
    )
os.chmod(os.path.join(BIN, "systemctl"), stat.S_IRWXU)

# A process whose comm is Runner.Worker, as in a job's container.
WORKER = [sys.executable, "-c", "import ctypes, time; ctypes.CDLL(None).prctl(15, b'Runner.Worker'); time.sleep(60)"]


def set_unit(number, state):
    with open(os.path.join(UNITS, f"myparcelle-ci-runner-{number}.service"), "w", encoding="ascii") as handle:
        handle.write(state + "\n")


def fixture_config(mem_available_kib=30 * 1024 * 1024):
    meminfo = os.path.join(ROOT, "meminfo")
    with open(meminfo, "w", encoding="ascii") as handle:
        handle.write(f"MemTotal: 33554432 kB\nMemAvailable: {mem_available_kib} kB\n")
    return admit.configuration(
        {
            "ADMIT_SLOTS": "4",
            "ADMIT_RESERVE_BYTES": str(RESERVE),
            "ADMIT_FLOOR_BYTES": str(FLOOR),
            "ADMIT_MEMINFO": meminfo,
            "ADMIT_SLICE_ROOT": os.path.join(ROOT, "cgroup"),
            "ADMIT_LEASE_ROOT": os.path.join(ROOT, "lease"),
            "ADMIT_STAMP_ROOT": os.path.join(ROOT, "stamp"),
            "ADMIT_SYSTEMCTL": os.path.join(BIN, "systemctl"),
        }
    )


def started():
    path = os.path.join(ROOT, "started")
    if not os.path.exists(path):
        return []
    with open(path, encoding="ascii") as handle:
        return handle.read().split()


def reset():
    for name in ("started", "stamp", "lease", "cgroup", "meminfo"):
        path = os.path.join(ROOT, name)
        shutil.rmtree(path, ignore_errors=True)
        if os.path.exists(path):
            os.remove(path)
    for number in range(1, 5):
        set_unit(number, "inactive")


def busy_slot(number, anon, shmem=0):
    """A slot cgroup holding a Runner.Worker and `anon` bytes of anonymous memory."""
    directory = os.path.join(ROOT, "cgroup", f"ciSlot{number}.slice", "docker-x.scope")
    os.makedirs(directory)
    process = subprocess.Popen(WORKER)
    for _ in range(200):
        with open(f"/proc/{process.pid}/comm", encoding="ascii") as comm:
            if comm.read().strip() == "Runner.Worker":
                break
        time.sleep(0.05)
    else:
        raise AssertionError("the stand-in worker never renamed itself")
    set_unit(number, "active")
    with open(os.path.join(directory, "cgroup.procs"), "w", encoding="ascii") as handle:
        handle.write(f"{process.pid}\n")
    with open(os.path.join(ROOT, "cgroup", f"ciSlot{number}.slice", "memory.stat"), "w", encoding="ascii") as handle:
        handle.write(f"anon {anon}\nfile 123\nshmem {shmem}\n")
    return process


reset()
check("a cold host starts slot 1", admit.tick(fixture_config(), now=1000.0), 1)
check("it recorded the start", started(), ["myparcelle-ci-runner-1.service"])
check("the started unit is idle: nothing more", admit.tick(fixture_config(), now=1006.0), None)

# The worker appears: slot 1 is busy, so slot 2 starts.
worker = busy_slot(1, 1 * GIB, 512 * 1024 * 1024)
try:
    check("a busy slot makes room for the next idle one", admit.tick(fixture_config(), now=1012.0), 2)
    # Slot 1 uses 1.5 GiB of its 6: 4.5 unspent. 30 - 4.5 - 3 = 22.5 >= 6, but slot 2 is now idle.
    check("one idle runner at a time", admit.tick(fixture_config(), now=1018.0), None)
finally:
    worker.kill()
    worker.wait()

# A tight host: the unspent reserve of a busy job keeps the next runner out.
reset()
worker = busy_slot(1, 0)
try:
    tight = (RESERVE + FLOOR + RESERVE - 1) // 1024
    check("not enough memory beyond the busy job's reserve", admit.tick(fixture_config(tight), now=2000.0), None)
    check("nothing was started", started(), [])
    check("enough memory", admit.tick(fixture_config(tight + 1), now=2006.0), 2)
finally:
    worker.kill()
    worker.wait()

# A fenced slot is never started, and its cooldown and lease behave.
reset()
os.makedirs(os.path.join(ROOT, "lease", "myparcelle-ci-slot-1"))
open(os.path.join(ROOT, "lease", "myparcelle-ci-slot-1", "lease"), "w").close()
check("a fenced slot 1 is skipped", admit.tick(fixture_config(), now=3000.0), 2)
set_unit(2, "inactive")
check("slot 2 just started: cooling, so slot 3", admit.tick(fixture_config(), now=3005.0), 3)
set_unit(3, "inactive")
set_unit(2, "inactive")
check("after the cooldown slot 2 again", admit.tick(fixture_config(), now=3030.0), 2)
check("never the fenced slot", "myparcelle-ci-runner-1.service" in started(), False)

# Fail closed: unreadable host state starts nothing.
reset()
config = fixture_config()
os.remove(config["meminfo"])
os.environ.update(
    {
        "ADMIT_SLOTS": "4",
        "ADMIT_RESERVE_BYTES": str(RESERVE),
        "ADMIT_FLOOR_BYTES": str(FLOOR),
        "ADMIT_MEMINFO": config["meminfo"],
        "ADMIT_SLICE_ROOT": config["slice_root"],
        "ADMIT_LEASE_ROOT": config["lease_root"],
        "ADMIT_STAMP_ROOT": config["stamp_root"],
        "ADMIT_SYSTEMCTL": config["systemctl"],
    }
)
check("an unreadable meminfo makes the tick fail", admit.main(), 1)
check("and starts nothing", started(), [])
set_unit(1, "weird")
fixture_config()
check("an unclassifiable unit makes the tick fail", admit.main(), 1)
check("and starts nothing either", started(), [])


# --- stress: more queued jobs than fit --------------------------------------
def stress(seed, total_gib, floor_gib, reserve_gib, slots, jobs, fenced):
    """Simulate whole ticks: jobs queue, an idle runner takes the next one, memory ramps to a peak."""
    rng = random.Random(seed)
    total = total_gib * GIB
    floor = floor_gib * GIB
    reserve = reserve_gib * GIB
    queue = [(rng.randint(1 * GIB, reserve), rng.randint(20, 120)) for _ in range(jobs)]  # (peak, duration in ticks)
    state = {n: ("fenced" if n in fenced else "down") for n in range(1, slots + 1)}
    job_of = {}
    done = 0
    peak_used = 0
    started_fenced = False
    most_in_flight = 0
    for tick_number in range(1, 100000):
        # jobs progress; a finished job frees its slot
        for n, job in list(job_of.items()):
            job["age"] += 1
            if job["age"] >= job["duration"]:
                del job_of[n]
                state[n] = "down"
                done += 1
        # an idle runner takes the next queued job
        for n in sorted(state):
            if state[n] == "idle" and queue:
                peak, duration = queue.pop(0)
                job_of[n] = {"peak": peak, "duration": duration, "age": 0}
                state[n] = "busy"

        def used(job):
            return min(job["peak"], job["peak"] * (job["age"] + 1) // 10)

        in_use = sum(used(job) for job in job_of.values())
        peak_used = max(peak_used, in_use)
        assert in_use <= total - floor, f"seed {seed} tick {tick_number}: {in_use // GIB} GiB used leaves the host below its floor"
        snapshot = [{"slot": n, "state": state[n], "used": used(job_of[n]) if n in job_of else 0} for n in sorted(state)]
        pick, _ = admit.decide(total - in_use, snapshot, reserve, floor)
        if pick is not None:
            assert state[pick] == "down", f"started a slot that was {state[pick]}"
            started_fenced = started_fenced or pick in fenced
            state[pick] = "idle"
        most_in_flight = max(most_in_flight, len(job_of))
        if done == jobs:
            break
    else:
        raise AssertionError(f"seed {seed}: {jobs - done} jobs starved")
    assert not started_fenced, "a fenced slot was started"
    return tick_number, most_in_flight, peak_used


for seed in range(25):
    ticks, most, peak = stress(seed, total_gib=32, floor_gib=3, reserve_gib=6, slots=6, jobs=60, fenced={3})
    assert most <= 6 and most >= 2, f"seed {seed}: {most} jobs at once"
# A host that fits only about three jobs still finishes everything, one idle runner at a time.
ticks, most, peak = stress(99, total_gib=22, floor_gib=3, reserve_gib=6, slots=6, jobs=40, fenced=set())
assert most <= 3, f"{most} jobs at once on a host that fits three"
print("myparcelle-ci-admit: all checks passed")
