{ lib, pkgs }:

let
  fixtures = import ../lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures)
    defaultsConfig
    policyConfig
    untrustedConfig
    yoloConfig
    ;
  plainSeedConfig = ../../pkgs/omp-configured/config/plain-seed.yml;
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

    status=0
    for config in \
      ${defaultsConfig} \
      ${untrustedConfig} \
      ${yoloConfig} \
      ${policyConfig} \
      ${plainSeedConfig}
    do
      # Repository role routes declare their selectors in this layer; a bundled
      # agent name is not itself a model role. Custom declared roles are valid.
      yq eval '.modelRoles // {} | keys | .[]' "$config" > "$TMPDIR/roles"
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
      while IFS= read -r alias; do
        case "$alias" in
          @*)
            if ! grep -qxF "''${alias#@}" "$TMPDIR/roles"; then
              printf 'model alias %s in %s has no declared modelRoles selector\n' \
                "$alias" "$config" >&2
              status=1
            fi
            ;;
        esac
      done < <(yq eval '.task.agentModelOverrides // {} | .[]' "$config")
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Concrete provider/model fallback keys are also supported upstream.
        case "$name" in */*) continue ;; esac
        if ! grep -qxF "$name" "$TMPDIR/roles"; then
          printf 'fallback chain %s in %s has no declared modelRoles selector\n' \
            "$name" "$config" >&2
          status=1
        fi
      done < <(yq eval '.retry.fallbackChains // {} | keys | .[]' "$config")
    done
    test "$status" -eq 0

    mkdir "$out"
  ''
