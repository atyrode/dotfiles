{ lib, pkgs, ... }:

let
  lichess = import ./pkgs/lichess.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
in
lib.mkIf pkgs.stdenv.isLinux {
  home.packages = with pkgs; [
    arduino-ide
    lichess
    parsec-bin
    plugdata
    steam
    steamcmd
    vital
    vlc
  ];
}
