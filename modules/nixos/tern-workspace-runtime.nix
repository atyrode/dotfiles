{
  config,
  host,
  lib,
  pkgs,
  utils,
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
  # Approved vendor executable for dev-01.
  approvedTern = {
    version = "0.9.33";
    sha256 = "13c714f3f8cb24a8fcbdd37ec98a4e9c87d51cb35746d2adad6f117459e298c7";
  };
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
    until [[ -S ${socket} && -n "$(${pkgs.iproute2}/bin/ss -Hx state listening src ${socket})" ]]; do
      ${pkgs.coreutils}/bin/sleep 0.1
    done
  '';
  daemonUnit = "tern-workspace-daemon.service";
  webUnit = "tern-workspace-web.service";
  wireguardUnit = "wireguard-${workspace.interface}.service";
  nativeName = "tern-workspace-native";
  nativeState = "/var/lib/${nativeName}";
  nativeRuntime = "/run/${nativeName}";
  nativePort = toString workspace.nativePort;
  nativePeers = lib.attrValues (workspace.selectNativePeers workspace.peers);
  nativeEnabled = workspace.serverPublicKey != null && nativePeers != [ ];
  nativeDependencies = [
    daemonUnit
    wireguardUnit
    "tern-workspace-ingress.service"
    "${utils.escapeSystemdPath "/sys/subsystem/net/devices/${workspace.interface}"}.device"
  ];
  nativeAuthorizedKeys = pkgs.writeText "tern-workspace-native-authorized-keys" (
    lib.concatMapStrings (peer: "${peer.nativePublicKey}\n") nativePeers
  );

  # systemd can proceed without a cgroup filter if BPF is unavailable. Check
  # the actual attachments before running Tern, with no test traffic.
  requireNativeFilters = pkgs.writeShellScript "tern-workspace-native-require-filters" ''
    set -euo pipefail
    if ! {
      IFS=: read -r hierarchy _ cgroup < /proc/self/cgroup &&
      [[ "$hierarchy" == 0 && "$cgroup" == /* ]] &&
      ${pkgs.bpftools}/bin/bpftool -j cgroup show "/sys/fs/cgroup$cgroup" |
        ${lib.getExe pkgs.jq} -e '
          map(.name) as $attached |
          ["sd_fw_ingress", "sd_fw_egress", "sd_restrictif_i", "sd_restrictif_e", "sd_bind4"] - $attached == []
        ' >/dev/null
    }; then
      echo "Tern native requires the systemd cgroup IP, interface and bind filters" >&2
      exit 1
    fi
  '';

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
    # NixOS starts the active target again on switch. The oneshot stages a new
    # executable without restarting the protected daemon or its frontends.
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe installTern} ${host.username} ${host.homeDirectory} ${binaryDirectory} ${approvedTern.version} ${approvedTern.sha256}";
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

  systemd.services.${nativeName} = lib.mkIf nativeEnabled (
    common
    // {
      description = "Private Tern workspace native frontend";
      # Dependency links leave the retained daemon unit definition unchanged.
      wantedBy = [
        daemonUnit
        wireguardUnit
      ];
      after = nativeDependencies;
      bindsTo = nativeDependencies;
      partOf = [
        daemonUnit
        wireguardUnit
      ];
      unitConfig."X-Atyrode-SessionOwner" = false;
      # Keep the native host identity across restarts, outside the daemon's
      # config and the browser token. The daemon socket remains unchanged.
      environment = common.environment // {
        HOME = nativeState;
        TERN_CONFIG_DIR = nativeState;
        XDG_RUNTIME_DIR = nativeRuntime;
      };
      serviceConfig = common.serviceConfig // {
        StateDirectory = nativeName;
        RuntimeDirectory = nativeName;
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = nativeState;
        InaccessiblePaths = [
          "-${configDir}/web-token"
          "-${home}/.ssh"
        ];
        ExecStartPre = [
          # The root probe must not load jq modules or shell state from the workspace.
          "+${pkgs.coreutils}/bin/env -i -C / HOME=/var/empty ${requireNativeFilters}"
          "${waitForDaemon}"
        ];
        TimeoutStartSec = "15s";
        # The built-in user-mode policy authenticates the explicit SSH key
        # list. This is Tern authentication, not an SSH server.
        ExecStart = "${tern} remote serve --user --listen ${workspace.serverAddress}:${nativePort} --state-dir ${nativeState} --relay none --authorized-keys ${nativeAuthorizedKeys}";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_NETLINK"
          "AF_UNIX"
        ];
        RestrictNetworkInterfaces = workspace.interface;
        IPAddressDeny = "any";
        IPAddressAllow = map (peer: "${peer.address}/32") nativePeers;
        SocketBindDeny = "any";
        SocketBindAllow = "ipv4:udp:${nativePort}";
      };
    }
  );
}
