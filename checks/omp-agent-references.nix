{ lib, pkgs }:

let
  fixtures = import ./lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures)
    defaultsConfig
    policyConfig
    untrustedConfig
    yoloConfig
    ;
  plainSeedConfig = ../omp/plain-seed.yml;
in
# Upstream agent renames and removals must fail the build instead of silently
# misrouting models: every referenced agent must exist in the pinned set.
pkgs.runCommand "check-omp-agent-references"
    {
      nativeBuildInputs = [
        pkgs.findutils
        pkgs.yq-go
      ];
    }
    ''
      find ${pkgs.omp-agents}/share/omp/agents -maxdepth 1 -name '*.md' -printf '%f\n' \
        | sed 's/\.md$//' > "$TMPDIR/agents"

      # Model roles with no backing agent file; every other routing key must
      # name an unpacked agent.
      printf '%s\n' default advisor smol slow plan tiny commit > "$TMPDIR/roles"

      status=0
      for config in \
        ${defaultsConfig} \
        ${untrustedConfig} \
        ${yoloConfig} \
        ${policyConfig} \
        ${plainSeedConfig}
      do
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          if ! grep -qxF "$name" "$TMPDIR/agents"; then
            printf 'unknown agent %s referenced by %s\n' "$name" "$config" >&2
            status=1
          fi
        done < <(
          yq eval \
            '(.task.agentModelOverrides // {} | keys | .[]), (.task.disabledAgents // [] | .[])' \
            "$config"
        )
        while IFS= read -r name; do
          [ -n "$name" ] || continue
          if ! grep -qxF "$name" "$TMPDIR/roles" && ! grep -qxF "$name" "$TMPDIR/agents"; then
            printf 'fallback chain %s in %s names neither a role nor an agent\n' \
              "$name" "$config" >&2
            status=1
          fi
        done < <(yq eval '.retry.fallbackChains // {} | keys | .[]' "$config")
      done
      test "$status" -eq 0

      mkdir "$out"
    ''
