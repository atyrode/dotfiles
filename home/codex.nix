{ lib, ... }:

let
  codexAgents = ../codex/AGENTS.md;
  codexConfig = ../codex/config.toml;
in
{
  # Codex/Home Manager wiring.
  #
  # AGENTS.md is a managed dotfiles file. config.toml is seeded only when a
  # profile has no config, because Codex stores mutable, machine-local state in
  # that file, especially [projects] trust entries for absolute checkout paths.
  home.activation.installCodexProfileFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    codex_agents_source="${codexAgents}"
    codex_config_source="${codexConfig}"

    install_codex_profile_files() {
      codex_profile_dir="$1"
      [ -d "$codex_profile_dir" ] || return 0

      chmod 700 "$codex_profile_dir"

      if [ -d "$codex_profile_dir/AGENTS.md" ] && [ ! -L "$codex_profile_dir/AGENTS.md" ]; then
        printf '%s\n' "Cannot manage $codex_profile_dir/AGENTS.md: it is a directory." >&2
        exit 1
      fi

      rm -f "$codex_profile_dir/AGENTS.md"
      ln -s "$codex_agents_source" "$codex_profile_dir/AGENTS.md"

      if [ ! -s "$codex_profile_dir/config.toml" ]; then
        if [ -d "$codex_profile_dir/config.toml" ] && [ ! -L "$codex_profile_dir/config.toml" ]; then
          printf '%s\n' "Cannot seed $codex_profile_dir/config.toml: it is a directory." >&2
          exit 1
        fi

        rm -f "$codex_profile_dir/config.toml"
        cp "$codex_config_source" "$codex_profile_dir/config.toml"
        chmod 600 "$codex_profile_dir/config.toml"
      fi
    }

    mkdir -p "$HOME/.codex"
    install_codex_profile_files "$HOME/.codex"

    if [ -d "$HOME/.codex-profiles" ]; then
      for codex_profile_dir in "$HOME/.codex-profiles"/*; do
        install_codex_profile_files "$codex_profile_dir"
      done
    fi
  '';
}
