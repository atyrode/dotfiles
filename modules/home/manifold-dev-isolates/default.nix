{ pkgs, ... }:

let
  holder = pkgs.writeScriptBin "manifold-dev-isolates" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ./holder.py}
  '';
in
{
  home.packages = [ holder ];
  systemd.user.slices.manifold-dev-isolates.Unit = {
    Description = "Manifold development sandbox delegation";
    "X-Atyrode-SessionOwner" = true;
    "X-SwitchMethod" = "keep-old";
    RefuseManualStop = true;
  };
  systemd.user.services.manifold-dev-isolates = {
    Unit = {
      Description = "Manifold development sandbox cgroup owner";
      "X-Atyrode-SessionOwner" = true;
      "X-SwitchMethod" = "keep-old";
      RefuseManualStop = true;
    };
    Service = {
      Type = "notify";
      NotifyAccess = "main";
      ExecStart = "${holder}/bin/manifold-dev-isolates hold";
      Delegate = "cpu memory pids";
      RuntimeDirectory = "manifold-dev-isolates";
      Slice = "manifold-dev-isolates.slice";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      # A manager stop must never kill guest processes. The holder also retains
      # itself on TERM while guest descendants exist or cannot be inspected.
      KillMode = "process";
      SendSIGKILL = false;
      TimeoutStartSec = 30;
      TimeoutStopSec = 30;
      Restart = "no";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
