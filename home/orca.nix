{ lib, pkgs, ... }:
{
  # Orca runs alongside Herdr during the trial. Every agent-tools host receives
  # the same desktop/headless binary: local apps can advertise themselves as a
  # server, while a headless machine can be started manually with `orca serve`.
  # Persistent service lifecycle, pairing addresses, firewall policy, and
  # secrets remain infrastructure concerns and are intentionally absent here.
  home.packages = [ pkgs.orca-ide ];

  # Headless `orca serve` otherwise auto-installs mutable launchers under
  # ~/.local/bin. Reserve both Linux command names with Home Manager links:
  # Orca detects them as foreign and leaves them alone, while shell and
  # Orca-managed terminals still resolve the repository-pinned package.
  home.file = lib.mkIf pkgs.stdenv.isLinux {
    ".local/bin/orca".source = lib.getExe pkgs.orca-ide;
    ".local/bin/orca-ide".source = "${pkgs.orca-ide}/bin/orca-ide";
  };
}
