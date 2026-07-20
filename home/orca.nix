{ pkgs, ... }:
{
  # Orca runs alongside Herdr during the trial. Every agent-tools host receives
  # the same desktop/headless binary: local apps can advertise themselves as a
  # server, while a headless machine can be started manually with `orca serve`.
  # Persistent service lifecycle, pairing addresses, firewall policy, and
  # secrets remain infrastructure concerns and are intentionally absent here.
  home.packages = [ pkgs.orca-ide ];
}
