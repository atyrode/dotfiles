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

  # Dial-out agent (wss, no inbound ports). The unit is inert until
  # `atyrode runtime provision manifold-agent` writes the 0600 machine token;
  # ConditionPathExists keeps an unenrolled machine at "skipped" instead of a
  # restart-looping failure. Fixed fleet machines use the committed registry
  # id; identity-free portable fixtures retain the hostname fallback.
  systemd.user.services.manifold-agent = lib.mkIf (supported && pkgs.stdenv.hostPlatform.isLinux) {
    Unit = {
      Description = "manifold machine agent";
      ConditionPathExists = "%h/.config/manifold/machine.token";
      # Restart=always must actually mean always: an instant crash loop at
      # RestartSec=3 stays under the default 5-per-10s burst only by a margin
      # of one, so disable the rate limit rather than depend on it.
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = lib.getExe pkgs.manifold-agent;
      # The token never enters the unit text or process environment listing;
      # the agent reads the file itself.
      Environment = [
        "MANIFOLD_SERVER_URL=${inventory.masterUrl}"
        "MANIFOLD_MACHINE_NAME=${machineName}"
        "MANIFOLD_MACHINE_TOKEN_FILE=%h/.config/manifold/machine.token"
      ];
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
      EnvironmentVariables = {
        MANIFOLD_SERVER_URL = inventory.masterUrl;
        MANIFOLD_MACHINE_TOKEN_FILE = tokenFile;
      }
      // lib.optionalAttrs (managedHostId != null) {
        MANIFOLD_MACHINE_NAME = managedHostId;
      };
      KeepAlive.PathState."${tokenFile}" = true;
      ProcessType = "Background";
      ThrottleInterval = 3;
      StandardOutPath = logFile;
      StandardErrorPath = logFile;
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
