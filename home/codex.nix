{ lib, pkgs, ... }:

{
  # The Codex profile system (codex-use + the `--profile atyrode` wrapper) was
  # retired. Codex now runs vanilla against ~/.codex: the curated defaults are a
  # one-time seed of config.toml (then fully user-owned), and the portable
  # guidance/assets are plain managed files. Auth, sessions, history, plugins,
  # caches, and machine-local config.toml trust entries stay Codex-owned.
  home.file = {
    ".codex/AGENTS.md".source = ../codex/AGENTS.md;
    ".codex/skills" = {
      source = ../codex/skills;
      recursive = true;
    };
    ".codex/templates" = {
      source = ../codex/templates;
      recursive = true;
    };
  };

  home.activation = {
    # Before Home Manager links the managed guidance files, clear the store
    # symlinks the retired codex-use converge left in ~/.codex so they do not
    # collide with the new home.file links. A one-time migration; a no-op after.
    clearRetiredCodexManagedFiles = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      for legacy in "$HOME/.codex/AGENTS.md" "$HOME/.codex/atyrode.config.toml"; do
        if [[ -L "$legacy" && "$(readlink "$legacy")" == /nix/store/* ]]; then
          if [[ -v DRY_RUN ]]; then
            echo "would remove retired managed symlink $legacy"
          else
            rm -f "$legacy"
          fi
        fi
      done
    '';

    # Seed the curated Codex defaults into the writable config once (then yours).
    # A failure warns instead of failing the whole activation.
    seedCodexConfig = lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" ] ''
      if [[ -v DRY_RUN ]]; then
        export AGENT_TOOLS_DRY_RUN=1
      fi
      if ! ${lib.getExe pkgs.codex-seed} apply; then
        echo "warning: codex config seeding failed; inspect with atyrode-codex-seed status" >&2
      fi
    '';
  };
}
