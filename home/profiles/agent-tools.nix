{
  lib,
  pkgs,
  ...
}:
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
      # Bun runs agent-generated local review proxies without falling back to
      # an unpinned, network-fetched runtime through `npx -y bun`.
      bun
      charm-freeze
      claude-code
      codex
      jetbrains-mono
      nerd-fonts.symbols-only
      # General-purpose JS runtime for agent tooling and one-off npx calls.
      nodejs_24
      tmux
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.bubblewrap
      # Agents inspect host user services and processes; carry the process
      # and user-service clients they need for that.
      pkgs.procps
      pkgs.systemd
    ];
}
