# ci-01's launcher against a real systemd and real memory: more queued jobs
# than the VM's memory fits, started only by the production timer and unit
# (myparcelle-ci-admit.nix). The stand-in runner units take a job when one is
# queued, hold the memory it asks for, then end, as a runner does after one job.
{ pkgs }:
let
  slots = 6;
  fenced = 3;
  jobs = 24;
  reserveMiB = 700;
  floorMiB = 900;
  runner = pkgs.writeText "stand-in-runner.py" ''
    import ctypes, os, sys, time

    slot = int(sys.argv[1])
    fixture = f"/run/fixture/ciSlot{slot}.slice/job.scope"
    pending, claimed, done = "/var/queue/pending", "/var/queue/claimed", "/var/queue/done"
    log = open("/var/queue/log", "a", buffering=1)
    stamp = lambda: f"{time.time():.2f}"

    def job():
        while True:
            for name in sorted(os.listdir(pending)):
                try:
                    os.rename(f"{pending}/{name}", f"{claimed}/{name}")
                except FileNotFoundError:
                    continue
                with open(f"{claimed}/{name}") as spec:
                    peak, seconds = map(int, spec.read().split())
                return name, peak, seconds
            time.sleep(0.2)

    name, peak, seconds = job()
    ctypes.CDLL(None).prctl(15, b"Runner.Worker")
    os.makedirs(fixture)
    with open(f"{fixture}/cgroup.procs", "w") as procs:
        procs.write(f"{os.getpid()}\n")
    log.write(f"start {slot} {name} {peak} {stamp()}\n")
    held = []
    while len(held) * 10 < peak:
        held.append(bytearray(b"x" * (10 * 1048576)))
        with open(f"/run/fixture/ciSlot{slot}.slice/memory.stat", "w") as stat:
            stat.write(f"anon {len(held) * 10 * 1048576}\nshmem 0\n")
        time.sleep(0.1)
    time.sleep(seconds)
    log.write(f"end {slot} {name} {peak} {stamp()}\n")
    os.rename(f"{claimed}/{name}", f"{done}/{name}")
    os.remove(f"{fixture}/cgroup.procs")
    os.rmdir(fixture)
    os.remove(f"/run/fixture/ciSlot{slot}.slice/memory.stat")
    os.rmdir(f"/run/fixture/ciSlot{slot}.slice")
  '';
in
pkgs.testers.runNixOSTest {
  name = "myparcelle-ci-admit";
  # Hosted Nix builders can run QEMU with software emulation.
  requiredFeatures.kvm = false;
  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ../../modules/nixos/myparcelle-ci-admit.nix ];
      virtualisation.memorySize = 3072;
      myparcelleCiAdmit = {
        inherit slots reserveMiB floorMiB;
        sliceRoot = "/run/fixture";
        cooldownSeconds = 2;
        intervalSeconds = 1;
      };
      systemd.tmpfiles.rules = [
        "d /var/queue 0755 root root -"
        "d /var/queue/pending 0755 root root -"
        "d /var/queue/claimed 0755 root root -"
        "d /var/queue/done 0755 root root -"
      ];
      systemd.services = lib.listToAttrs (
        map (
          slot:
          lib.nameValuePair "myparcelle-ci-runner-${toString slot}" {
            unitConfig.ConditionPathExists = "!/var/lib/myparcelle-ci-slot-${toString slot}/lease";
            serviceConfig = {
              ExecStart = "${pkgs.python3}/bin/python3 ${runner} ${toString slot}";
              Restart = "no";
              # The host keeps what the launcher leaves it, not the job's own limit.
              OOMScoreAdjust = 500;
            };
          }
        ) (lib.range 1 slots)
      );
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /var/lib/myparcelle-ci-slot-${toString fenced} && touch /var/lib/myparcelle-ci-slot-${toString fenced}/lease")

    # Nothing queued: the launcher still keeps exactly one idle runner.
    machine.wait_until_succeeds("systemctl is-active myparcelle-ci-runner-1")
    machine.sleep(5)
    active = machine.succeed("systemctl list-units 'myparcelle-ci-runner-*' --state=active --no-legend | wc -l").strip()
    assert active == "1", f"expected exactly one idle runner, got {active}"

    # More jobs than the memory fits: 24 jobs of 150-650 MiB, 4-9 s each.
    machine.succeed(
        "for i in $(seq 1 ${toString jobs}); do "
        "echo \"$((150 + i * 37 % 500)) $((4 + i % 6))\" > /var/queue/pending/$(printf %03d $i); done"
    )
    machine.wait_until_succeeds("test $(ls /var/queue/done | wc -l) -eq ${toString jobs}", timeout=600)

    report = machine.succeed("""${pkgs.python3}/bin/python3 - <<'PY'
    import collections
    events = []
    for line in open('/var/queue/log'):
        kind, slot, name, peak, t = line.split()
        events.append((float(t), kind, int(slot), int(peak)))
    events.sort()
    live, most, slots_used = {}, 0, collections.Counter()
    worst = 0
    for t, kind, slot, peak in events:
        if kind == 'start':
            live[slot] = peak
            slots_used[slot] += 1
        else:
            del live[slot]
        most = max(most, len(live))
        worst = max(worst, sum(live.values()))
    print(f"most={most} worst_promised_mib={worst} slots={dict(slots_used)}")
    PY""")
    print(report)
    most = int(report.split("most=")[1].split()[0])
    assert 2 <= most <= ${toString (slots - 1)}, f"concurrency {most} out of range"
    assert "${toString fenced}:" not in report.split("slots=")[1].replace(" ", ""), "the fenced slot ran a job"

    # No kernel OOM kill and no failed unit: the launcher kept the host inside its memory.
    machine.fail("dmesg | grep -i 'out of memory'")
    machine.fail("journalctl -u 'myparcelle-ci-runner-*' | grep -i 'killed\\|oom'")
    machine.succeed("test $(systemctl list-units --failed --no-legend | wc -l) -eq 0")
    machine.fail("systemctl is-active myparcelle-ci-runner-${toString fenced}")
  '';
}
