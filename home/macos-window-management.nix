{ lib, pkgs, ... }:

{
  home.packages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.skhd
    pkgs.yabai
  ];
}
