{
  config,
  lib,
  pkgs,
  ...
}:

let
  inventory = builtins.fromJSON (builtins.readFile ../../../fleet/manifold.json);
  supported = builtins.elem pkgs.stdenv.hostPlatform.system inventory.supportedSystems;
  managedHostId = config.home.sessionVariables.ATYRODE_HOST or null;
  machineName = if managedHostId == null then "%H" else managedHostId;
  tokenFile = "${config.home.homeDirectory}/.config/manifold/machine.token";
  stateDirectory = "${config.home.homeDirectory}/.local/state/manifold";
  logFile = "${stateDirectory}/agent.log";
  terminalHostProtocol = pkgs.manifold-agent.terminalHostProtocol or 0;
  split = terminalHostProtocol == 1;
  terminalHostSocket = "${stateDirectory}/terminal-host/host.sock";
  # A loaded terminal owner must not be replaced because a transport package
  # changed. The stable profile path is used only when the owner next starts;
  # the running process retains its binary and all terminal state.
  terminalHostCommand = "${config.home.profileDirectory}/bin/manifold-agent";
  darwinAgent =
    if managedHostId != null then
      lib.getExe pkgs.manifold-agent
    else
      pkgs.writeShellScript "manifold-agent-with-hostname" ''
        export MANIFOLD_MACHINE_NAME="$(/usr/bin/hostname)"
        exec ${lib.getExe pkgs.manifold-agent}
      '';
in
{
  home.packages = lib.optionals supported [ pkgs.manifold-agent ];
  assertions = lib.optional supported {
    assertion = builtins.elem terminalHostProtocol [ 0 1 ];
    message = "Unsupported manifold terminal-host protocol; update the service topology before activating this pin.";
  };

  # Dial-out agent (wss, no inbound ports). The unit is inert until
  # `atyrode runtime provision manifold-agent` writes the 0600 machine token;
  # ConditionPathExists keeps an unenrolled machine at "skipped" instead of a
  # restart-looping failure. Fixed fleet machines use the committed registry
  # id; identity-free portable fixtures retain the hostname fallback.
  systemd.user.services.manifold-agent = lib.mkIf (supported && pkgs.stdenv.hostPlatform.isLinux) {
    Unit = {
      Description = "manifold machine agent";
      ConditionPathExists = "%h/.config/manifold/machine.token";
      "X-Atyrode-SessionOwner" = !split;
      # Restart=always must actually mean always: an instant crash loop at
      # RestartSec=3 stays under the default 5-per-10s burst only by a margin
      # of one, so disable the rate limit rather than depend on it.
      StartLimitIntervalSec = 0;
    }
    // lib.optionalAttrs (!split) {
      "X-SwitchMethod" = "keep-old";
      RefuseManualStop = true;
    }
    // lib.optionalAttrs split {
      Wants = [ "manifold-terminal-host.service" ];
      After = [ "manifold-terminal-host.service" ];
    };
    Service = {
      ExecStart = lib.getExe pkgs.manifold-agent;
      # The token never enters the unit text or process environment listing;
      # the agent reads the file itself.
      Environment = [
        "MANIFOLD_SERVER_URL=${inventory.masterUrl}"
        "MANIFOLD_MACHINE_NAME=${machineName}"
        "MANIFOLD_MACHINE_TOKEN_FILE=%h/.config/manifold/machine.token"
      ] ++ lib.optional split "MANIFOLD_TERMINAL_HOST_SOCKET=${terminalHostSocket}";
      Restart = "always";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.manifold-terminal-host =
    lib.mkIf (supported && split && pkgs.stdenv.hostPlatform.isLinux) {
      Unit = {
        Description = "manifold terminal owner";
        ConditionPathExists = "%h/.config/manifold/machine.token";
        "X-Atyrode-SessionOwner" = true;
        "X-SwitchMethod" = "keep-old";
        RefuseManualStop = true;
        StartLimitIntervalSec = 0;
      };
      Service = {
        ExecStart = "${terminalHostCommand} --terminal-host";
        Environment = [ "MANIFOLD_TERMINAL_HOST_SOCKET=${terminalHostSocket}" ];
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "default.target" ];
    };

  # launchd's PathState is both the enrollment gate and the durable restart
  # contract: loading this plist without a token starts nothing, while placing
  # the token later starts the agent and keeps it alive. Home Manager derives
  # the label org.nix-community.home.manifold-agent from this attribute name.
  launchd.agents.manifold-agent = lib.mkIf (supported && pkgs.stdenv.hostPlatform.isDarwin) {
    enable = true;
    config = {
      ProgramArguments = [ darwinAgent ];
      "X-Atyrode-SessionOwner" = !split;
      EnvironmentVariables = {
        MANIFOLD_SERVER_URL = inventory.masterUrl;
        MANIFOLD_MACHINE_TOKEN_FILE = tokenFile;
      }
      // lib.optionalAttrs (managedHostId != null) {
        MANIFOLD_MACHINE_NAME = managedHostId;
      }
      // lib.optionalAttrs split {
        MANIFOLD_TERMINAL_HOST_SOCKET = terminalHostSocket;
      };
      KeepAlive.PathState."${tokenFile}" = true;
      ProcessType = "Background";
      ThrottleInterval = 3;
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
    };
  };

  # The plist uses no package-version path, so Home Manager leaves the loaded
  # owner alone when it replaces the transport's versioned plist. Explicit
  # owner-definition changes still pass through the disruption guard.
  launchd.agents.manifold-terminal-host =
    lib.mkIf (supported && split && pkgs.stdenv.hostPlatform.isDarwin) {
      enable = true;
      config = {
        ProgramArguments = [ terminalHostCommand "--terminal-host" ];
        "X-Atyrode-SessionOwner" = true;
        EnvironmentVariables.MANIFOLD_TERMINAL_HOST_SOCKET = terminalHostSocket;
        KeepAlive.PathState."${tokenFile}" = true;
        ProcessType = "Background";
        ThrottleInterval = 3;
        StandardOutPath = "${stateDirectory}/terminal-host.log";
        StandardErrorPath = "${stateDirectory}/terminal-host.log";
      };
    };

  home.activation.createManifoldStateDirectory =
    lib.mkIf (supported && pkgs.stdenv.hostPlatform.isDarwin)
      (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg stateDirectory}
        ''
      );
}
