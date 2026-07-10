{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/home/agent-tools.nix
    ../codex.nix
  ];

  atyrode.agentTools.enable = true;

  home.packages =
    (with pkgs; [
      codex-configured
      codex-use
      tmux
    ])
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ];
}
