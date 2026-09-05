# What atyrode itself puts on a machine beyond its binary: the converge floor
# (ADR 0008, "The flow", step 3) and the one line the login shell says about
# it. A fleet member left alone converges to green main on this timer; a
# portable profile is not a fleet member, has no ATYRODE_HOST, and gets no
# timer, exactly as `atyrode apply --unattended` refuses it.
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

  # No Install on the service: a converge can download a whole generation, and
  # a job that long inside the startup transaction would hold user-manager
  # readiness at "starting" (the babel-archive service says the same). The
  # timer triggers it. The unattended apply hands itself to the supervised
  # atyrode-apply.service like any other, so an activation that restarts the
  # user manager does not kill the run that started it.
  systemd.user.services.atyrode-converge =
    lib.mkIf (fleetMember && pkgs.stdenv.hostPlatform.isLinux)
      {
        Unit = {
          Description = "Converge this machine to the published main (atyrode apply --unattended)";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "oneshot";
          ExecStart = "${atyrode} apply ${managedHostId} --unattended";
        };
      };

  # Every six hours, spread over half an hour so three machines never fetch
  # from the cache at the same minute, and Persistent so a machine that slept
  # through a slot converges when it wakes. Often enough that the shell knows
  # the same day when an update is waiting; cheap when nothing changed, since
  # a machine found current costs one ls-remote and no build. Push-on-green is
  # the fast path; this is the floor beneath it.
  systemd.user.timers.atyrode-converge = lib.mkIf (fleetMember && pkgs.stdenv.hostPlatform.isLinux) {
    Unit.Description = "Converge of this machine to the published main, every six hours";
    Timer = {
      OnCalendar = "*-*-* 00/6:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # launchd coalesces a calendar interval missed in sleep into one run at wake,
  # which is the Persistent= behaviour above. On a Mac the run holds before it
  # builds anything, because nix-darwin activation elevates and sudo asks; the
  # receipt it leaves is what the shell then says.
  launchd.agents.atyrode-converge = lib.mkIf (fleetMember && pkgs.stdenv.hostPlatform.isDarwin) {
    enable = true;
    config = {
      ProgramArguments = [
        atyrode
        "apply"
        managedHostId
        "--unattended"
      ];
      StartCalendarInterval =
        map
          (hour: {
            Hour = hour;
            Minute = 0;
          })
          [
            0
            6
            12
            18
          ];
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

  # One muted line, read from the receipt alone: a prompt never waits on the
  # network. Only a login shell on a terminal gets it, and only when the last
  # unattended run held or failed; a converged machine says nothing.
  programs.zsh.initContent = lib.mkIf fleetMember (
    lib.mkAfter ''
      if [[ -o interactive && -t 1 ]]; then
        ${atyrode} __converge-notice
      fi
    ''
  );
}
