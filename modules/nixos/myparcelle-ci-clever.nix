# On-demand CI machines for myParcelle on Clever Cloud (myParcelle's
# deploy/README.md § CI runners on Clever Cloud): the controller that starts one
# Clever application per GitHub Actions job labelled `clever` and stops it when
# the job ends. The machines themselves run on Clever; only the controller runs
# here, beside the dev-01 runners it does not replace (they stay registered as
# the fallback, see myparcelle-ci-runners.nix).
#
#   code        myParcelle's deploy/ci-runners/, taken from the development
#               checkout's origin/main (the reviewed code, never its working
#               tree) at each start; restart the unit to pick up a newer main.
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
  checkout = "/home/alex/myParcelle";
  source = "${stateDirectory}/source";

  # Root, before each start: the controller's files from origin/main.
  exportController = pkgs.writeShellApplication {
    name = "myparcelle-ci-clever-export";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.gnutar
    ];
    text = ''
      rm -rf ${source}.next
      install -d -m 0755 ${source}.next
      git -c safe.directory='*' --git-dir=${checkout}/.git archive refs/remotes/origin/main deploy/ci-runners |
        tar -x -C ${source}.next
      rm -rf ${source}
      mv ${source}.next ${source}
    '';
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
    unitConfig.ConditionPathExists = "${tokenDirectory}/clever-oauth.json";
    # GitHub or Clever unreachable: retry forever.
    startLimitIntervalSec = 0;
    environment.HOME = stateDirectory;
    serviceConfig = {
      User = user;
      Group = user;
      StateDirectory = user;
      StateDirectoryMode = "0755";
      UMask = "0022";
      ExecStartPre = "+${lib.getExe exportController}";
      ExecStart = "${lib.getExe pkgs.bun} ${source}/deploy/ci-runners/controller.ts";
      LoadCredential = [
        "github-token:${tokenDirectory}/github-token"
        "clever-oauth:${tokenDirectory}/clever-oauth.json"
        "discord:/home/alex/.config/myparcelle/discord-bot.env"
      ];
      Restart = "always";
      RestartSec = 30;
      # Stopping closes the message session only: running machines keep their
      # jobs and the next start adopts them.
      TimeoutStopSec = 30;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
    };
  };
}
