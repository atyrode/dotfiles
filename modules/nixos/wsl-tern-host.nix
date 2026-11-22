{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  topology = import ../../fleet/wsl-tern-host.nix;
  inherit (host) username homeDirectory;
  port = toString topology.port;
  listenAddress = topology.address;
  ingressUnit = "wsl-tern-ingress.service";

  wireguardUnit = "wireguard-${topology.interface}.service";
  daemonUnit = "wsl-tern-daemon.service";
  installUnit = "wsl-tern-install.service";
  nativeName = "wsl-tern-native";
  nativeState = "/var/lib/${nativeName}";
  nativeRuntime = "/run/${nativeName}";

  # Stencil's official Linux release; the helper refuses any other bytes.
  ternVersion = "0.9.30";
  ternDigest = "4e054c72848d6ea874a86e28c5f9c50e7b1eb9c66de6674a120e21f2581d3635";

  binaryDirectory = "/var/lib/wsl-tern-bin";
  tern = "${binaryDirectory}/tern";
  # Dedicated state: this daemon's panes and checkpoints live beside its own
  # socket, apart from any Tern the operator runs by hand.
  configDir = "${homeDirectory}/.local/state/tern-wsl";
  socket = "${configDir}/daemon.sock";

  # The reviewed helper (pinned Tern version and digest below) does the verified copy.
  # The vendor binary is installed locally by the operator; when it has not
  # been staged yet there is nothing to verify, so skip quietly and let the
  # daemon's condition keep Tern off. A present but unapproved binary still
  # fails closed inside the helper.
  installHelper = pkgs.writeShellApplication {
    name = "wsl-tern-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      source=${homeDirectory}/.local/bin/tern
      if [[ ! -e ${tern} && ! -e $source && ! -L $source ]]; then
        echo "WSL Tern: $source is not installed; Tern stays off until the operator installs the approved ${ternVersion} and starts ${installUnit}" >&2
        exit 0
      fi
      exec ${
        lib.getExe (
          pkgs.writeShellApplication {
            name = "tern-workspace-install";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.util-linux
            ];
            text = builtins.readFile ./tern-workspace-install.sh;
          }
        )
      } ${username} ${homeDirectory} ${binaryDirectory} ${ternVersion} ${ternDigest}
    '';
  };

  waitForDaemon = pkgs.writeShellScript "wsl-tern-wait-for-daemon" ''
    until [[ -S ${socket} && -n "$(${pkgs.iproute2}/bin/ss -Hx state listening src ${socket})" ]]; do
      ${pkgs.coreutils}/bin/sleep 0.1
    done
  '';

  authorizedKeys = pkgs.writeText "wsl-tern-native-authorized-keys" "${topology.clientPublicKey}\n";

  environment = {
    # System services do not inherit nix-ld's login environment.
    inherit (config.environment.sessionVariables) NIX_LD NIX_LD_LIBRARY_PATH;
    TERN_CONFIG_DIR = configDir;
    TERN_DAEMON_SOCKET = socket;
  };
in
{
  assertions = [
    {
      assertion =
        builtins.match "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-P][A-Za-z0-9+/]{42}" topology.clientPublicKey
        != null;
      message = "WSL Tern authorizes only the Mac's configured Tern Ed25519 public key";
    }
  ];

  programs.nix-ld.enable = true;

  systemd.services.wsl-tern-install = {
    description = "Provision the approved Tern executable for the WSL host";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe installHelper;
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

  # Hosts the real user's panes in their own environment. It does not depend
  # on the frontend or the tunnel, and activation never restarts it: a restart
  # would end the panes it owns.
  systemd.services.wsl-tern-daemon = {
    description = "Tern session daemon for the WSL user";
    wantedBy = [ "multi-user.target" ];
    requires = [ installUnit ];
    after = [ installUnit ];
    unitConfig = {
      "X-Atyrode-SessionOwner" = true;
      ConditionPathExists = tern;
    };
    restartIfChanged = false;
    stopIfChanged = false;
    environment = environment // {
      HOME = homeDirectory;
      PATH = lib.mkForce "${binaryDirectory}:/etc/profiles/per-user/${username}/bin:/run/wrappers/bin:/run/current-system/sw/bin";
      SHELL = lib.getExe pkgs.zsh;
    };
    serviceConfig = {
      Type = "exec";
      User = username;
      WorkingDirectory = homeDirectory;
      ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0700 ${configDir}";
      ExecStart = "${tern} daemon";
      # An emptied owner can exit cleanly; bring it back without connecting.
      Restart = "always";
      RestartSec = "2s";
      ExecStartPost = "${waitForDaemon}";
      TimeoutStartSec = "15s";
      LimitCORE = 0;
    };
  };

  systemd.services.${nativeName} = {
    description = "Tern native frontend for the WSL host";
    # Boot lifecycle (daemon, tunnel) and guard recovery (ingress) all pull the
    # frontend in, so starting the fixed guard is enough; the daemon is never
    # restarted. BindsTo/After on the guard still keep it from listening
    # whenever the guard is not active.
    wantedBy = [
      daemonUnit
      wireguardUnit
      ingressUnit
    ];
    # The frontend follows the daemon and the tunnel; neither follows it.
    after = [
      daemonUnit
      wireguardUnit
      ingressUnit
    ];
    bindsTo = [
      daemonUnit
      wireguardUnit
      ingressUnit
    ];
    partOf = [
      wireguardUnit
      ingressUnit
    ];
    unitConfig = {
      "X-Atyrode-SessionOwner" = false;
      ConditionPathExists = tern;
    };
    environment = environment // {
      HOME = nativeState;
      TERN_CONFIG_DIR = nativeState;
      XDG_RUNTIME_DIR = nativeRuntime;
      PATH = lib.mkForce "${binaryDirectory}:/run/current-system/sw/bin";
    };
    serviceConfig = {
      Type = "exec";
      User = username;
      StateDirectory = nativeName;
      StateDirectoryMode = "0700";
      RuntimeDirectory = nativeName;
      RuntimeDirectoryMode = "0700";
      WorkingDirectory = nativeState;
      UMask = "0077";
      ExecStartPre = waitForDaemon;
      TimeoutStartSec = "15s";
      # Tern's built-in user-mode policy authenticates the explicit key list.
      # This is Tern authentication, not an SSH server, and has no relay.
      ExecStart = "${tern} remote serve --user --listen [${listenAddress}]:${port} --state-dir ${nativeState} --relay none --authorized-keys ${authorizedKeys}";
      Restart = "on-failure";
      RestartSec = "2s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      BindPaths = configDir;
      PrivateTmp = true;
      LimitCORE = 0;
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      RestrictAddressFamilies = [
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
      SocketBindDeny = "any";
      SocketBindAllow = "ipv6:udp:${port}";
    };
  };
}
