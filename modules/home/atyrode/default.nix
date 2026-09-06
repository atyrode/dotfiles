# What atyrode itself puts on a machine beyond its binary: an hourly look at
# main and the one line every new shell says while an update is waiting (ADR
# 0008, "The flow", step 5). Nothing here activates anything: an update is a
# prompt, and `atyrode apply` is the operator's answer to it. A portable
# profile is not a fleet member, has no ATYRODE_HOST, and gets none of this.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  managedHostId = config.home.sessionVariables.ATYRODE_HOST or null;
  fleetMember = managedHostId != null;
  atyrode = lib.getExe pkgs.atyrode;
in
{
  home.packages = [ pkgs.atyrode ];

  # No Install on the service: the timer triggers it, so a first look at main
  # never sits inside the startup transaction.
  systemd.user.services.atyrode-update-check =
    lib.mkIf (fleetMember && pkgs.stdenv.hostPlatform.isLinux)
      {
        Unit = {
          Description = "Record what main has that this machine does not (atyrode changelog --record)";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${atyrode} changelog --record";
        };
      };

  # Hourly: a machine that is current costs one ls-remote, and one behind costs
  # two anonymous GitHub reads, so the price of knowing within the hour is
  # nothing. Persistent so a machine that slept catches up at wake; a short
  # startup delay so a fresh login learns about an update without waiting for
  # the top of the hour.
  systemd.user.timers.atyrode-update-check =
    lib.mkIf (fleetMember && pkgs.stdenv.hostPlatform.isLinux)
      {
        Unit.Description = "Hourly look at what main has that this machine does not";
        Timer = {
          OnStartupSec = "5m";
          OnCalendar = "hourly";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };

  launchd.agents.atyrode-update-check = lib.mkIf (fleetMember && pkgs.stdenv.hostPlatform.isDarwin) {
    enable = true;
    config = {
      ProgramArguments = [
        atyrode
        "changelog"
        "--record"
      ];
      StartInterval = 3600;
      RunAtLoad = true;
      ProcessType = "Background";
      EnvironmentVariables.PATH = lib.concatStringsSep ":" [
        "/etc/profiles/per-user/${config.home.username}/bin"
        "/run/current-system/sw/bin"
        "/nix/var/nix/profiles/default/bin"
        "/usr/bin"
        "/bin"
      ];
    };
  };

  # One muted line, read from the record alone -- a prompt never waits on the
  # network -- in every interactive shell on a terminal while an update is
  # waiting. Every shell, deliberately: a shell an agent opened and closed must
  # not be the one that dismissed it. Silent once the machine runs main.
  programs.zsh.initContent = lib.mkIf fleetMember (
    lib.mkAfter ''
      if [[ -o interactive && -t 1 ]]; then
        ${atyrode} __update-notice
      fi
    ''
  );
}
