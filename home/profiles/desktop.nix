{ lib, pkgs, ... }:
let
  lichess = import ../pkgs/lichess.nix {
    inherit lib pkgs;
  };
in
{
  imports = [
    ../linux-desktop.nix
    ../rio.nix
  ];

  # Retention of desktop applications reflects operator use, not the agent
  # baseline. Homebrew-owned applications remain in the nix-darwin module.
  home.packages = lib.optionals pkgs.stdenv.isDarwin (
    (with pkgs; [
      chatgpt
      obsidian
      postman
      prismlauncher
      reaper
      signal-desktop
      spotify
      vlc-bin
      whatsapp-for-mac
    ])
    ++ [ lichess ]
  );
}
