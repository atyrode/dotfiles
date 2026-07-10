{ lib, pkgs, ... }:
let
  lichess = import ../pkgs/lichess.nix {
    inherit lib pkgs;
  };
in
{
  imports = [ ../linux-desktop.nix ];

  # Retention of desktop applications reflects operator use, not the agent
  # baseline. Homebrew-owned applications remain in the nix-darwin module.
  home.packages = lib.optionals pkgs.stdenv.isDarwin (
    (with pkgs; [
      chatgpt
      godot
      obsidian
      orbstack
      postman
      prismlauncher
      reaper
      signal-desktop
      spotify
      vlc-bin
      vscode
      whatsapp-for-mac
    ])
    ++ [ lichess ]
  );
}
