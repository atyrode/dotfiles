{ lib, pkgs, ... }:

let
  inventory = builtins.fromJSON (builtins.readFile ../../inventory/manifold.json);
  # Upstream publishes compiled release assets per platform and only
  # x86_64-linux exists today; unsupported systems keep evaluating (and
  # keep the capability selectable) without referencing an unbuildable
  # package. Widen inventory/manifold.json supportedSystems as upstream
  # assets land. Supported systems are Linux, so the systemd unit gate below
  # collapses to the same condition.
  supported = builtins.elem pkgs.stdenv.hostPlatform.system inventory.supportedSystems;
in
{
  home.packages = lib.optionals supported [ pkgs.manifold-agent ];

  # Dial-out agent (wss, no inbound ports). The unit is inert until
  # `atyrode runtime provision manifold-agent` writes the 0600 machine token;
  # ConditionPathExists keeps an unenrolled machine at "skipped" instead of a
  # restart-looping failure. Home Manager's default sd-switch start discipline
  # restarts the unit only when its rendered text changes (a manifold pin bump
  # or config change), never on an unrelated apply; a restart kills the PTYs
  # the agent owns, so pin bumps on a machine hosting live sessions are
  # operator-timed (docs/manifold.md).
  systemd.user.services.manifold-agent = lib.mkIf supported {
    Unit = {
      Description = "manifold machine agent";
      ConditionPathExists = "%h/.config/manifold/machine.token";
      # Restart=always must actually mean always: an instant crash loop at
      # RestartSec=3 stays under the default 5-per-10s burst only by a
      # margin of one, so disable the rate limit rather than depend on it.
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = lib.getExe pkgs.manifold-agent;
      # The token never enters the unit text or process environment listing;
      # the agent reads the file itself. The machine name is the hostname
      # (%H = gethostname), the same source provisioning enrolls with.
      Environment = [
        "MANIFOLD_SERVER_URL=${inventory.masterUrl}"
        "MANIFOLD_MACHINE_NAME=%H"
        "MANIFOLD_MACHINE_TOKEN_FILE=%h/.config/manifold/machine.token"
      ];
      Restart = "always";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
