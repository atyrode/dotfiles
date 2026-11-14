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
# Native routing must remain shared-role-only; disabled agent references must
# still exist in the pinned bundle.
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
      yq eval '.modelRoles // {} | keys | .[]' "$config" > "$TMPDIR/roles"
      if [ "$(yq eval '.task // {} | has("agentModelOverrides")' "$config")" != false ]; then
        printf 'per-agent model routing emitted by %s\n' "$config" >&2
        status=1
      fi
      while IFS= read -r role; do
        case "$role" in
          default|smol|slow|plan|task|advisor|tiny|commit|vision|widget) ;;
          *)
            printf 'non-native shared model role %s in %s\n' "$role" "$config" >&2
            status=1
            ;;
        esac
      done < "$TMPDIR/roles"
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if ! grep -qxF "$name" "$TMPDIR/agents"; then
          printf 'unknown agent %s referenced by %s\n' "$name" "$config" >&2
          status=1
        fi
      done < <(
        yq eval '.task.disabledAgents // [] | .[]' "$config"
      )
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
