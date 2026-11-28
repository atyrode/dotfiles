# The launcher half of ci-01's runners: a timer that keeps exactly one idle
# runner unit started, and starts the next only while live memory covers a
# whole job. The decision lives in myparcelle-ci-admit.py; its design and the
# reasoning for the numbers are in myparcelle-ci-ci-01.nix (§ Launcher).
#
# The module only starts `myparcelle-ci-runner-<n>.service` for n in 1..slots.
# What those units are (real runners on ci-01, stand-ins in the VM test that
# exercises this module) is the importer's business, as is each slot's cgroup
# slice `ciSlot<n>.slice` under `sliceRoot`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.myparcelleCiAdmit;
  admit = pkgs.writers.writePython3Bin "myparcelle-ci-admit" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./myparcelle-ci-admit.py);
in
{
  options.myparcelleCiAdmit = {
    slots = lib.mkOption {
      type = lib.types.ints.positive;
      description = "How many runner units (myparcelle-ci-runner-1..N) the launcher may start.";
    };
    reserveMiB = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Memory one job is assumed to need: a startup budget, and the slots' MemoryMax.";
    };
    floorMiB = lib.mkOption {
      type = lib.types.ints.unsigned;
      description = "Memory left to the host: never offered to a new runner.";
    };
    sliceRoot = lib.mkOption {
      type = lib.types.str;
      description = "Cgroup directory holding each slot's ciSlot<n>.slice.";
    };
    leaseRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib";
      description = "Directory of the myparcelle-ci-slot-<n>/lease quarantine files.";
    };
    meminfo = lib.mkOption {
      type = lib.types.str;
      default = "/proc/meminfo";
      description = "Where MemAvailable is read; a fixture in tests only.";
    };
    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 20;
      description = "A slot that just ended is not started again for this long.";
    };
    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Delay between two admission decisions.";
    };
  };

  config = {
    systemd.services.myparcelle-ci-admit = {
      description = "Start ci-01's next idle runner while memory covers a job";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe admit;
        Environment = [
          "ADMIT_SLOTS=${toString cfg.slots}"
          "ADMIT_RESERVE_BYTES=${toString (cfg.reserveMiB * 1048576)}"
          "ADMIT_FLOOR_BYTES=${toString (cfg.floorMiB * 1048576)}"
          "ADMIT_COOLDOWN_SECONDS=${toString cfg.cooldownSeconds}"
          "ADMIT_SLICE_ROOT=${cfg.sliceRoot}"
          "ADMIT_LEASE_ROOT=${cfg.leaseRoot}"
          "ADMIT_MEMINFO=${cfg.meminfo}"
          "ADMIT_SYSTEMCTL=${config.systemd.package}/bin/systemctl"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        # Start stamps (the per-slot cooldown) must outlive each tick.
        RuntimeDirectory = "myparcelle-ci-admit";
        RuntimeDirectoryPreserve = true;
      };
    };

    systemd.timers.myparcelle-ci-admit = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.intervalSeconds}s";
        OnUnitInactiveSec = "${toString cfg.intervalSeconds}s";
        AccuracySec = "1s";
      };
    };
  };
}
