# The cost guard of myParcelle's CI machines on Clever Cloud (myParcelle's
# docs/workflows/DELIVERY.md § Clever cost guard): a small program every two
# minutes, apart from the controller (myparcelle-ci-clever.nix), sharing no
# code and no state with it. It reads Clever itself (applications, instances,
# telemetry) and stops `myparcelle-ci-<n>` machines that run too long, too
# many at once, or past the spend caps; it fails closed when it cannot read
# Clever. The program's header lists the rules.
#
#   caps        /etc/myparcelle-ci-clever-guard.env, from `caps` below:
#               €15 a Paris day, €100 a month (Clever's prices, excluding
#               VAT), 70 min per instance, CI_CLEVER_MAX_MACHINES at once
#               (keep it equal to the controller's), 15 min blind before
#               failing closed. A one-day exception to the day cap names its
#               Paris date (`<date>:<EUR>`): the guard ignores it on any other
#               day and tells #alertes once to remove it.
#   kill switch a cap reached writes the latch `${latch}`.
#               While it exists, systemd stops the controller and refuses to
#               start it (and the controller refuses by itself), the guard
#               stops any CI machine it sees and keeps CI_RUNS_ON on dev-01.
#               Only a human removes it, after reading why (`cat` it):
#                 sudo rm ${latch}
#                 sudo systemctl start myparcelle-ci-clever.service
#   user        `myparcelle-ci-clever-guard`, a system account with no login;
#               it cannot stop units itself: the latch's path unit does.
#   credentials the controller's Clever OAuth token, the runners' GitHub token
#               (CI_RUNS_ON) and the Discord env file (#alertes), as systemd
#               credentials, never in the environment, argv or logs.
#   test        one tick by hand with other caps, posting nothing (the
#               program's defaults are the caps below, the dated override
#               aside; an EnvironmentFile would override every -E):
#                 sudo systemd-run --wait --pipe --collect \
#                   -p User=myparcelle-ci-clever-guard \
#                   -p StateDirectory=myparcelle-ci-clever-guard \
#                   -p LoadCredential=clever-oauth:/var/lib/myparcelle-ci-runners/clever-oauth.json \
#                   -p LoadCredential=github-token:/var/lib/myparcelle-ci-runners/github-token \
#                   -E TZDIR=/etc/zoneinfo -E CI_CLEVER_QUIET=1 \
#                   -E CI_CLEVER_GUARD_MAX_AGE_MIN=1 \
#                   /run/current-system/sw/bin/myparcelle-ci-clever-guard [--report]
#               `--report` only reads and prints.
{ lib, pkgs, ... }:
let
  user = "myparcelle-ci-clever-guard";
  stateDirectory = "/var/lib/${user}";
  latch = "${stateDirectory}/kill-switch";
  tokenDirectory = "/var/lib/myparcelle-ci-runners";
  controller = "myparcelle-ci-clever.service";

  caps = {
    CI_CLEVER_GUARD_DAY_EUR = "15";
    # The operator's exception for the first day of the trial's full load.
    CI_CLEVER_GUARD_DAY_EUR_OVERRIDE = "2026-11-16:30";
    CI_CLEVER_GUARD_MONTH_EUR = "100";
    CI_CLEVER_GUARD_MAX_AGE_MIN = "70";
    CI_CLEVER_MAX_MACHINES = "40";
    CI_CLEVER_GUARD_BLIND_MIN = "15";
  };

  guard = pkgs.writers.writePython3Bin user {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./myparcelle-ci-clever-guard.py);
in
{
  users = {
    groups.${user} = { };
    users.${user} = {
      isSystemUser = true;
      group = user;
      home = stateDirectory;
    };
  };

  environment.systemPackages = [ guard ];
  environment.etc."${user}.env".text = lib.concatStrings (
    lib.mapAttrsToList (name: value: "${name}=${value}\n") caps
  );

  systemd.services.${user} = {
    description = "myParcelle CI on Clever Cloud: cost guard (caps, machine age and count, kill switch)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${tokenDirectory}/clever-oauth.json";
    environment = {
      CI_CLEVER_KILL_SWITCH = latch;
      CI_CLEVER_GUARD_CONTROLLER = controller;
    };
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      # 0755: the controller reads the latch.
      StateDirectory = user;
      StateDirectoryMode = "0755";
      UMask = "0022";
      EnvironmentFile = "/etc/${user}.env";
      ExecStart = lib.getExe guard;
      LoadCredential = [
        "clever-oauth:${tokenDirectory}/clever-oauth.json"
        "github-token:${tokenDirectory}/github-token"
        "discord:/home/alex/.config/myparcelle/discord-bot.env"
      ];
      # A kill switch waits up to 75 s for the controller to stop its machines.
      TimeoutStartSec = 110;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
    };
  };
  systemd.timers.${user} = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
      AccuracySec = "5s";
    };
  };

  # The latch stops the controller: starting this unit stops the controller
  # (Conflicts), and it stays active while the latch exists. Starting the
  # controller again stops it, and the path unit, seeing the latch still
  # there, starts it again.
  systemd.paths."${user}-kill-switch" = {
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathExists = latch;
      Unit = "${user}-kill-switch.service";
    };
  };
  systemd.services."${user}-kill-switch" = {
    description = "myParcelle CI on Clever Cloud: the cost guard's kill switch keeps the controller stopped";
    conflicts = [ controller ];
    after = [ controller ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/echo 'kill switch latched (${latch}): ${controller} stopped; only a human removes the latch'";
    };
  };
  # And refuses to start it.
  systemd.services.myparcelle-ci-clever.unitConfig.ConditionPathExists = [ "!${latch}" ];
}
