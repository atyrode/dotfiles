# On-demand CI machines for myParcelle on Clever Cloud (myParcelle's
# deploy/README.md § CI runners on Clever Cloud): the controller that starts one
# Clever application per GitHub Actions job labelled `clever` and stops it when
# the job ends. The machines themselves run on Clever; only the controller runs
# here, beside the dev-01 runners it does not replace (they stay registered as
# the fallback, see myparcelle-ci-runners.nix).
#
#   code        myParcelle's deploy/ci-runners/ from a root-owned copy,
#               /var/lib/myparcelle-ci-clever-source/deploy/ci-runners,
#               placed by hand from a reviewed commit (myParcelle's
#               deploy/README.md § CI runners on Clever Cloud); the service
#               account can read it but not change it. Refresh, then restart:
#                 sudo rm -rf /var/lib/myparcelle-ci-clever-source/deploy
#                 git -C ~/myParcelle archive <commit> deploy/ci-runners |
#                   sudo tar -x -C /var/lib/myparcelle-ci-clever-source
#               Until the copy is placed, neither unit starts.
#   user        `myparcelle-ci-clever`, a system account with no login, no
#               Docker and no access to /home.
#   credentials root-only files, handed to the unit as systemd credentials and
#               never in its environment or argv:
#                 github-token  the runners' fine-grained token (Administration
#                               and Variables: write on the repository),
#                               shared with myparcelle-ci-runners.nix;
#                 clever-oauth  the controller's own Clever credential: an
#                               OAuth token of the consumer
#                               `myparcelle-ci-controller` (parcel-app; rights:
#                               access organisations, manage their
#                               applications), approved by the operator in his
#                               browser through myParcelle's
#                               deploy/ci-runners/mint-clever-token.ts. Revoke:
#                               `clever oauth-consumers delete
#                               myparcelle-ci-controller`;
#                 discord       the operator's Discord env file, for the
#                               #alertes webhook (DISCORD_ALERTS_WEBHOOK_URL).
#               Until the Clever credential is placed, the unit does not start.
#   state       /var/lib/myparcelle-ci-clever: ledger.jsonl (one line per
#               machine session, with its cost), daily-cost.log, status.json;
#               world-readable, no secret in it, read by `bun run ci:cost`.
{ lib, pkgs, ... }:
let
  user = "myparcelle-ci-clever";
  stateDirectory = "/var/lib/${user}";
  tokenDirectory = "/var/lib/myparcelle-ci-runners";
  source = "/var/lib/myparcelle-ci-clever-source";

  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
  };
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

  systemd.services.myparcelle-ci-clever = {
    description = "myParcelle CI machines on Clever Cloud (one per job, stopped after it)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = [
      "${tokenDirectory}/clever-oauth.json"
      "${source}/deploy/ci-runners/controller.ts"
    ];
    # GitHub or Clever unreachable: retry forever.
    startLimitIntervalSec = 0;
    environment.HOME = stateDirectory;
    serviceConfig = hardening // {
      User = user;
      Group = user;
      StateDirectory = user;
      StateDirectoryMode = "0755";
      UMask = "0022";
      ExecStart = "${lib.getExe pkgs.bun} ${source}/deploy/ci-runners/controller.ts";
      LoadCredential = [
        "github-token:${tokenDirectory}/github-token"
        "clever-oauth:${tokenDirectory}/clever-oauth.json"
        "discord:/home/alex/.config/myparcelle/discord-bot.env"
      ];
      Restart = "always";
      RestartSec = 30;
      # Stopping stops every machine it runs (Clever's stop calls, retried),
      # then closes the message session: nothing keeps running unwatched.
      TimeoutStopSec = 90;
    };
  };

  # The dead-man's switch, apart from the controller: while CI_RUNS_ON names
  # the `clever` labels, jobs waiting three minutes with the controller down
  # (or no runner registered at all) send CI back to dev-01 and alert
  # #alertes (myParcelle's deploy/ci-runners/watchdog.ts).
  systemd.services.myparcelle-ci-clever-watchdog = {
    description = "myParcelle CI on Clever Cloud: route back to dev-01 when nothing serves the jobs";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${source}/deploy/ci-runners/watchdog.ts";
    environment.HOME = stateDirectory;
    serviceConfig = hardening // {
      Type = "oneshot";
      User = user;
      Group = user;
      StateDirectory = user;
      StateDirectoryMode = "0755";
      ExecStart = "${lib.getExe pkgs.bun} ${source}/deploy/ci-runners/watchdog.ts";
      LoadCredential = [
        "github-token:${tokenDirectory}/github-token"
        "discord:/home/alex/.config/myparcelle/discord-bot.env"
      ];
      TimeoutStartSec = 50;
    };
  };
  systemd.timers.myparcelle-ci-clever-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      AccuracySec = "5s";
    };
  };
}
