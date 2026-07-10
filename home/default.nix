{ pkgs, ... }:

{
  imports = [
    ../modules/home/agent-tools.nix
    ./codex.nix
    ./packages.nix
    ./mise.nix
    ./zsh.nix
    ./git.nix
  ];

  atyrode.agentTools.enable = true;

  # Home Manager uses this as a compatibility marker for stateful defaults.
  # Keep it fixed after first activation unless you explicitly review the
  # release notes for every version being skipped.
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;
}
