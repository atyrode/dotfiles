{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/home/agent-tools.nix
    ../claude.nix
    ../codex.nix
  ];

  atyrode.agentTools.enable = true;

  # Terminal-viewing stack for the tui-visual-verification skill (#163): tmux
  # drives and captures the TUI under test, charm-freeze renders the ANSI
  # capture to PNG, and the two fonts make those renders faithful (JetBrains
  # Mono for text, Nerd Font symbols for PUA glyphs). ttyd/vhs are deliberately
  # left out: that stack proved flaky in agent sandboxes and remains an
  # on-demand `nix shell` tool for live watching only.
  fonts.fontconfig.enable = true;

  home.packages =
    (with pkgs; [
      charm-freeze
      claude-code
      codex
      jetbrains-mono
      nerd-fonts.symbols-only
      tmux
    ])
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ];
}
