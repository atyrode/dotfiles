{
  config,
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
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.bubblewrap
      # Agents inspect host user services and processes; carry the process
      # and user-service clients they need for that.
      pkgs.procps
      pkgs.systemd
    ];

  # One-time reconciliation for dropping the Orca integration: removes the
  # user-local launchers Orca's headless installer created and its mutable
  # state directory. Drop this block once every managed host has applied it.
  home.activation.removeOrcaArtifacts = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        binDirectory=${lib.escapeShellArg "${config.home.homeDirectory}/.local/bin"}
        orcaState=${lib.escapeShellArg "${config.home.homeDirectory}/.orca"}

        orcaIde="$binDirectory/orca-ide"
        orcaIdeTarget="$(${pkgs.coreutils}/bin/readlink "$orcaIde" 2>/dev/null || :)"
        case "$orcaIdeTarget" in
          /nix/store/*-orca-ide-*-extracted/resources/bin/orca-ide)
            if [[ -v DRY_RUN ]]; then
              echo "Would remove Orca-managed launcher $orcaIde"
            else
              ${pkgs.coreutils}/bin/rm -f "$orcaIde"
            fi
            ;;
        esac

        orcaLauncher="$binDirectory/orca"
        if [[ -f "$orcaLauncher" && ! -L "$orcaLauncher" ]] \
          && ${pkgs.gnugrep}/bin/grep -qF '# orca-serve-bare-orca-dispatcher' "$orcaLauncher"; then
          if [[ -v DRY_RUN ]]; then
            echo "Would remove Orca-managed dispatcher $orcaLauncher"
          else
            ${pkgs.coreutils}/bin/rm -f "$orcaLauncher"
          fi
        fi

        if [[ -e "$orcaState" ]]; then
          if [[ -v DRY_RUN ]]; then
            echo "Would remove Orca state directory $orcaState"
          else
            ${pkgs.coreutils}/bin/chmod -R u+w "$orcaState" || :
            ${pkgs.coreutils}/bin/rm -rf "$orcaState"
          fi
        fi
      ''
  );

  # Retire only the mutable OMP extension installed by the removed multiplexer
  # integration. Preserve its state and worktree directories as user data.
  home.activation.removeRetiredOmpIntegration =
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        shopt -s nullglob
        retiredIntegrations=(
          "$HOME/.omp/agent/extensions/herdr-omp-agent-state.ts"
          "$HOME"/.omp/profiles/*/agent/extensions/herdr-omp-agent-state.ts
        )
        if [[ -n "''${PI_CODING_AGENT_DIR:-}" ]]; then
          retiredAgentDir="$PI_CODING_AGENT_DIR"
          case "$retiredAgentDir" in
            "~") retiredAgentDir="$HOME" ;;
            "~/"*) retiredAgentDir="$HOME/''${retiredAgentDir#\~/}" ;;
          esac
          retiredIntegrations+=( "$retiredAgentDir/extensions/herdr-omp-agent-state.ts" )
        fi
        for retiredIntegration in "''${retiredIntegrations[@]}"; do
          if [[ -e "$retiredIntegration" || -L "$retiredIntegration" ]]; then
            if [[ -v DRY_RUN ]]; then
              echo "Would remove retired OMP integration $retiredIntegration"
            else
              ${pkgs.coreutils}/bin/rm -f -- "$retiredIntegration"
            fi
          fi
        done
        shopt -u nullglob
        ${lib.optionalString pkgs.stdenv.isLinux ''
          if [[ -v DRY_RUN ]]; then
            echo "Would stop the retired usage publisher user service"
          else
            ${pkgs.systemd}/bin/systemctl --user stop atyrode-herdr-usage-publisher.service \
              >/dev/null 2>&1 || :
          fi
        ''}
      '';
}
