# dev-01 only. The application operator stages a reviewed, root-owned Bun
# entrypoint and locally provisions two host-encrypted systemd credentials.
# None of those deployment inputs is copied from a mutable agent checkout by
# the service, and no credential is a Nix input.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "myparcelle-ci-hook";
  entry = "/etc/myparcelle-ci-status/webhook.ts";
  credentials = "/etc/credstore.encrypted";
  credential = name: "${credentials}/myparcelle-ci-hook-${name}.cred";
  repositories = [
    "myparcelle"
    "dotfiles"
  ];
in
{
  options.atyrode.myparcelle.ciStatusWebhook.enable =
    lib.mkEnableOption "the isolated GitHub CI status ingress on dev-01";

  config = lib.mkIf config.atyrode.myparcelle.ciStatusWebhook.enable {
    users.groups.${user} = { };
    users.users.${user} = {
      isSystemUser = true;
      group = user;
    };

    systemd.services.myparcelle-ci-status-webhook = {
      description = "myParcelle CI status webhook ingress";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = [ entry ] ++ map credential repositories;
      serviceConfig = {
        ExecStart = "${pkgs.bun}/bin/bun --no-env-file ${entry}";
        User = user;
        Group = user;
        LoadCredentialEncrypted = map (name: "${name}:${credential name}") repositories;
        StateDirectory = user;
        # The user-level status writer can read opaque wake markers, not credentials.
        StateDirectoryMode = "0755";
        UMask = "0022";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [ "AF_INET" ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        MemoryMax = "128M";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
