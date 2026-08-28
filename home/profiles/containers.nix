{ lib, pkgs, ... }:
{
  # This capability installs clients and inspection tools only. Daemon and
  # rootless-engine ownership remains with the system layer on Linux. OrbStack
  # is the selected Darwin engine and retains its own runtime state.
  home.packages =
    lib.optionals pkgs.stdenv.hostPlatform.isLinux (
      with pkgs;
      [
        docker
        docker-compose
      ]
    )
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.orbstack ];
}
