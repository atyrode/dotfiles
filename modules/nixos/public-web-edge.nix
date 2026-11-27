# The web front of a machine that serves virtual hosts: Caddy, and TCP 80 and
# 443 beside the SSH port modules/nixos/vps.nix always opens. The edge modules
# lib/configurations.nix imports with this one only add virtual hosts; a
# machine that serves none (ci-01) imports neither and listens on SSH alone.
{ lib, ... }:
{
  services.caddy.enable = true;

  # mkForce like vps.nix's list: equal priorities merge, so the ports add to
  # SSH's instead of the plain default losing to it.
  networking.firewall.allowedTCPPorts = lib.mkForce [
    80
    443
  ];
}
