{ lib, pkgs, ... }:
{
  # This capability installs clients and inspection tools only. Daemon and
  # desktop-engine ownership remains with the system/desktop layers.
  home.packages = [
    pkgs.dive
  ]
  ++ lib.optionals pkgs.stdenv.isLinux (
    with pkgs;
    [
      docker
      docker-compose
    ]
  );
}
