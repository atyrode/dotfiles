{ lib, pkgs, ... }:
let
  lichess = import ../desktop/lichess.nix { inherit lib pkgs; };
in
{
  imports = [
    ../desktop/linux.nix
    ../desktop/fonts.nix
  ];

  # Retention of desktop applications reflects operator use, not the agent
  # baseline. Homebrew-owned applications remain in the nix-darwin module.
  # Signal is one of them: nixpkgs has no cached aarch64-darwin build, so as a
  # Nix package it was a multi-hour Electron compile on every fresh machine and
  # every CI run, for a bundle that then carried no vendor signature. The cask
  # is the vendor-signed release and installs in seconds.
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isDarwin (
    (with pkgs; [
      chatgpt
      obsidian
      postman
      prismlauncher
      reaper
      spotify
      vlc-bin
    ])
    ++ [ lichess ]
  );
}
