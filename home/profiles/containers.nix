{ lib, pkgs, ... }:
{
  # This capability installs clients and inspection tools only. Daemon and
  # rootless-engine ownership remains with the system layer on Linux. OrbStack
  # is the selected Darwin engine and retains its own runtime state.
  home.packages = [
    pkgs.dive
  ]
  ++ lib.optionals pkgs.stdenv.isLinux (
    with pkgs;
    [
      docker
      docker-compose
    ]
  )
  ++ lib.optionals pkgs.stdenv.isDarwin [ pkgs.orbstack ];
}
