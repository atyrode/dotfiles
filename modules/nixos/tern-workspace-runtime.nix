{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  workspace = import ../../fleet/tern-workspace.nix;
  user = "tern-workspace";
  home = "/var/lib/${user}";
  runtime = "/run/${user}";
  configDir = "${home}/.config/tern";
  # Tern checkpoints panes beside its socket. A socket in /run loses that state at boot.
  socket = "${configDir}/daemon.sock";
  binaryDirectory = "/var/lib/tern-workspace-bin";
  tern = "${binaryDirectory}/tern";
  installUnit = "tern-workspace-install.service";
  installTern = pkgs.writeShellApplication {
    name = "tern-workspace-install";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./tern-workspace-install.sh;
  };

  # Check the kernel's listener table: the socket file alone can be stale.
  waitForDaemon = pkgs.writeShellScript "tern-workspace-wait-for-daemon" ''
    until [[ -S ${socket} && -n "$(${pkgs.iproute2}/bin/ss -Hlx src ${socket})" ]]; do
      ${pkgs.coreutils}/bin/sleep 0.1
    done
  '';
  daemonUnit = "tern-workspace-daemon.service";
  webUnit = "tern-workspace-web.service";

  common = {
    environment = {
      # System services do not inherit nix-ld's login environment.
      inherit (config.environment.sessionVariables) NIX_LD NIX_LD_LIBRARY_PATH;
      HOME = home;
      # Native agent blocks need the fleet's pinned omp, not the operator's user profile.
      PATH = lib.mkForce "${binaryDirectory}:${
        lib.makeBinPath [
          pkgs.omp
          pkgs.git
        ]
      }:/run/current-system/sw/bin";
      SHELL = "${pkgs.bashInteractive}/bin/bash";
      TERN_CONFIG_DIR = configDir;
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

  # Copy only the approved executable from the existing local installation;
  # the vendor binary and the operator's account state stay outside the store.
  systemd.services.tern-workspace-install = {
    description = "Provision the approved private Tern workspace executable";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe installTern} ${host.username} ${host.homeDirectory} ${binaryDirectory}";
      TimeoutStartSec = "45s";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectHome = "read-only";
      ProtectSystem = "full";
      LimitCORE = 0;
    };
  };

  systemd.services.tern-workspace-daemon = common // {
    description = "Private Tern workspace session daemon";
    wantedBy = [ "multi-user.target" ];
    wants = [ webUnit ];
    requires = [ installUnit ];
    after = [ installUnit ];
    unitConfig."X-Atyrode-SessionOwner" = true;
    serviceConfig = common.serviceConfig // {
      RuntimeDirectory = user;
      RuntimeDirectoryMode = "0700";
      ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0700 ${configDir}";
      ExecStart = "${tern} daemon";
      # The last client can leave an empty owner to exit cleanly. Restart it
      # without connecting at startup, which would arm that idle timeout again.
      Restart = "always";
      ExecStartPost = "${waitForDaemon}";
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
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      SocketBindDeny = "any";
      SocketBindAllow = "ipv4:tcp:${toString workspace.webPort}";
      # Tern creates and reuses .config/tern/web-token, but prints it to both streams.
      StandardOutput = "null";
      StandardError = "null";
    };
  };
}
