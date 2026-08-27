{ lib, pkgs, ... }:

let
  lichess = import ./desktop/lichess.nix { inherit lib pkgs; };
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
