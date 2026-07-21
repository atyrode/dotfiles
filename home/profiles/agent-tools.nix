{ lib, pkgs, ... }:
{
  imports = [
    ../../modules/home/agent-tools.nix
    ../claude.nix
    ../codex.nix
    ../herdr.nix
    ../orca.nix
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
      # npx supports Orca's skill registry and powers its remote SSH relay.
      nodejs_24
      tmux
    ])
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.bubblewrap
      # Orca terminals run inside an AppImage FHS root that masks the host
      # /usr. Carry the user-service and process clients agents need to inspect
      # the host through its mounted D-Bus socket and /proc.
      pkgs.procps
      pkgs.systemd
    ];
}
