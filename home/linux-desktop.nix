{ pkgs, ... }:

let
  lichess = import ./pkgs/lichess.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
in
{
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
