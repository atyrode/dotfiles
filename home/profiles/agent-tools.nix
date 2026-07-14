{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/home/agent-tools.nix
    ../claude.nix
    ../codex.nix
  ];

  atyrode.agentTools.enable = true;

  home.packages =
    (with pkgs; [
      claude-code
      codex
      tmux
    ])
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ];
}
