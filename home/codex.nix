{ lib, pkgs, ... }:

{
  # Codex runs vanilla against ~/.codex. Curated defaults seed config.toml once
  # (then become fully user-owned); portable guidance/templates are managed.
  # Auth, sessions, history, plugins, caches, and machine-local trust remain
  # Codex-owned.
  home.file = {
    ".codex/AGENTS.md".source = ../codex/AGENTS.md;
    ".codex/templates" = {
      source = ../codex/templates;
      recursive = true;
    };
  };

  # Seed the curated Codex defaults into the writable config once (then yours).
  # A failure warns instead of failing the whole activation.
  home.activation.seedCodexConfig = lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" ] ''
    if [[ -v DRY_RUN ]]; then
      export AGENT_TOOLS_DRY_RUN=1
    fi
    if ! ${lib.getExe pkgs.codex-seed} apply; then
      echo "warning: codex config seeding failed; inspect with atyrode-codex-seed status" >&2
    fi
  '';
}
