{ config, pkgs, ... }:
let
  workspace = import ../../fleet/tern-workspace.nix;
  user = "tern-workspace";
  home = "/var/lib/${user}";
  runtime = "/run/${user}";
  socket = "${runtime}/daemon.sock";
  binaryDirectory = "/var/lib/tern-workspace-bin";
  tern = "${binaryDirectory}/tern";
  daemonUnit = "tern-workspace-daemon.service";
  webUnit = "tern-workspace-web.service";

  common = {
    unitConfig.ConditionFileIsExecutable = tern;
    environment = {
      # System services do not inherit nix-ld's login environment.
      inherit (config.environment.sessionVariables) NIX_LD NIX_LD_LIBRARY_PATH;
      HOME = home;
      PATH = "${binaryDirectory}:/run/current-system/sw/bin";
      SHELL = "${pkgs.bashInteractive}/bin/bash";
      TERN_CONFIG_DIR = "${home}/.config/tern";
      TERN_DAEMON_SOCKET = socket;
      XDG_RUNTIME_DIR = runtime;
    };
    serviceConfig = {
      User = user;
      Group = user;
      Type = "exec";
      StateDirectory = user;
      StateDirectoryMode = "0700";
      WorkingDirectory = home;
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = "2s";
      NoNewPrivileges = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      LimitCORE = 0;
    };
  };
in
{
  users.groups.${user} = { };
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    inherit home;
    shell = pkgs.bashInteractive;
  };

  # The operator installs the upstream executable here, outside the Nix store.
  systemd.tmpfiles.rules = [ "d ${binaryDirectory} 0755 root root -" ];

  systemd.services.tern-workspace-daemon = common // {
    description = "Private Tern workspace session daemon";
    wantedBy = [ "multi-user.target" ];
    wants = [ webUnit ];
    serviceConfig = common.serviceConfig // {
      RuntimeDirectory = user;
      RuntimeDirectoryMode = "0700";
      ExecStart = "${tern} daemon";
      # Type=exec guarantees only that the binary started, not that its socket exists.
      ExecStartPost = "${pkgs.bash}/bin/bash -c 'until test -S ${socket}; do ${pkgs.coreutils}/bin/sleep 0.1; done'";
      TimeoutStartSec = "15s";
    };
  };

  systemd.services.tern-workspace-web = common // {
    description = "Private Tern workspace web frontend";
    after = [ daemonUnit ];
    bindsTo = [ daemonUnit ];
    partOf = [ daemonUnit ];
    serviceConfig = common.serviceConfig // {
      ExecStart = "${tern} web serve --listen 127.0.0.1:${toString workspace.webPort} --allow-origin https://${workspace.hostname}";
      # Tern creates and reuses .config/tern/web-token, but prints it to both streams.
      StandardOutput = "null";
      StandardError = "null";
    };
  };
}
