{ pkgs, ... }:

{
  home.packages = with pkgs; [
    arduino-ide
    parsec-bin
    steam
    steamcmd
    vlc
  ];
}
