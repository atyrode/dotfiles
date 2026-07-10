{ pkgs, ... }:
{
  home.packages = with pkgs; [
    clamav
    nmap
    socat
  ];
}
