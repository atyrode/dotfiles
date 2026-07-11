{ pkgs, ... }:
{
  # Antivirus requires system-owned signature updates and a scanning workflow.
  # No registered host has that policy, so ClamAV is intentionally absent.
  home.packages = with pkgs; [
    nmap
    socat
  ];
}
