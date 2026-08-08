{ lib, pkgs, ... }:

{
  home.packages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.yabai
  ];
}
