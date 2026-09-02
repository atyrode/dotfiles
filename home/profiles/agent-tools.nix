{
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../../modules/home/agent-tools.nix
    ../agents.nix
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

  # Babel refuses to guess who is judging: review and reality decisions are
  # attributed operator decisions (atyrode/babel SPEC.md §4.7), taken from
  # --operator or $BABEL_OPERATOR. Every managed home already commits as
  # exactly one person (git.nix), so the same reviewed-commit authorization
  # names that person as Babel's operator; without this, `babel web` serves
  # read-only and refuses judgment clicks with a warning at launch.
  home.sessionVariables.BABEL_OPERATOR = "alex";

  home.packages =
    (with pkgs; [
      # Babel itself (atyrode/babel), pinned by flake.lock. It replaced the
      # rclone-crypt session-backup job: same trees, but session-aware, with
      # integrity verification, selective restore, and a shared catalog. The
      # operator drives it directly as `babel archive status|verify|push`;
      # the hourly timer in modules/home/agent-tools.nix runs the same binary
      # from its absolute store path.
      babel
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
      # Babel's archival engine (atyrode/babel SPEC.md 2.3): it encrypts and
      # deduplicates this machine's agent session history. It belongs to this
      # capability rather than base because the sessions Babel archives are
      # exactly what agent-tools installs, so every machine that produces them
      # can also preserve them. The version is pinned by flake.lock, and the
      # retention policy is append-only: Babel never runs `restic forget` or
      # `restic prune`.
      restic
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
