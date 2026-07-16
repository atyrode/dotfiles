{ pkgs }:

let
  seedConfig = ../omp/plain-seed.yml;
  policyConfig = ../omp/policy.yml;
in
pkgs.runCommand "check-omp-seed"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
      pkgs.omp-seed
    ];
  }
  ''
    set -euo pipefail

    fail() {
      echo "FAIL: $1" >&2
      exit 1
    }

    seed='${seedConfig}'
    policy='${policyConfig}'

    # The seed must parse and stay a mapping.
    yq eval '.' "$seed" >/dev/null || fail "plain-seed.yml is not valid YAML"

    # Where the seed overlaps enforced policy, the values must agree so plain
    # omp is never seeded weaker (or differently) than managed launchers are
    # forced. The shared-leaf count is asserted non-zero so this can never
    # silently become vacuous.
    seed_json="$(yq eval -o=json '.' "$seed")"
    policy_json="$(yq eval -o=json '.' "$policy")"
    overlap="$(jq -n --argjson seed "$seed_json" --argjson policy "$policy_json" '
      def haspath($doc; $p):
        $doc
        | try (reduce ($p[:-1])[] as $k (.; .[$k]) | (type == "object") and has($p[-1]))
          catch false;
      [ $policy
        | paths as $p
        | select((($p | map(type) | any(. == "number")) | not)
                 and (($policy | getpath($p) | type) != "object"))
        | $p ] as $pleaves
      | { shared: [ $pleaves[] as $p
            | if haspath($seed; $p) then ($p | join(".")) else empty end ],
          mismatched: [ $pleaves[] as $p
            | if haspath($seed; $p) and (($seed | getpath($p)) != ($policy | getpath($p)))
              then ($p | join("."))
              else empty
              end ] }')"
    [ "$(jq -r '.shared | length' <<<"$overlap")" != 0 ] \
      || fail "seed/policy overlap assertion is vacuous: no shared leaves found"
    [ "$(jq -r '.mismatched | length' <<<"$overlap")" = 0 ] \
      || fail "seed disagrees with enforced policy on: $(jq -r '.mismatched | join(", ")' <<<"$overlap")"

    # Scenario: dry run on a pristine machine writes nothing at all — not
    # even the state directory or lock file.
    export HOME="$TMPDIR/pristine"
    mkdir -p "$HOME"
    AGENT_TOOLS_DRY_RUN=1 atyrode-omp-seed apply >"$TMPDIR/dry-pristine.log"
    grep -q 'dry run' "$TMPDIR/dry-pristine.log" || fail "pristine dry run was not announced"
    [ ! -e "$HOME/.local/state/atyrode/omp-plain-seed" ] || fail "pristine dry run created state"
    [ ! -e "$HOME/.omp" ] || fail "pristine dry run touched ~/.omp"

    # Scenario: first boot with no config file at all.
    export HOME="$TMPDIR/firstboot"
    mkdir -p "$HOME"
    atyrode-omp-seed apply >"$TMPDIR/firstboot.log"
    config="$HOME/.omp/agent/config.yml"
    [ -f "$config" ] || fail "first boot did not create config.yml"
    [ "$(stat -c '%a' "$config")" = "600" ] || fail "first boot config mode is not 600"
    [ "$(yq eval '.secrets.enabled' "$config")" = "true" ] || fail "first boot did not seed secrets.enabled"
    [ "$(yq eval '.task.disabledAgents | length' "$config")" = "0" ] || fail "first boot did not seed empty disabledAgents"

    # Scenario: a profile-scoped agent environment must never redirect the
    # seeder. PI_CODING_AGENT_DIR points at a decoy profile root; apply must
    # leave the decoy untouched and seed the default root anyway (issue #173:
    # `atyrode apply` run from inside an omp session leaked the session's
    # profile into the seeder).
    export HOME="$TMPDIR/envleak"
    decoy="$HOME/.omp/profiles/decoy/agent"
    mkdir -p "$HOME" "$decoy"
    printf 'setupVersion: 1\n' >"$decoy/config.yml"
    decoy_before="$(cat "$decoy/config.yml")"
    PI_CODING_AGENT_DIR="$decoy" atyrode-omp-seed apply >"$TMPDIR/envleak.log"
    [ "$(cat "$decoy/config.yml")" = "$decoy_before" ] || fail "profile env redirected seeding into the decoy root"
    [ -f "$HOME/.omp/agent/config.yml" ] || fail "profile env prevented seeding the default root"
    PI_CODING_AGENT_DIR="$decoy" atyrode-omp-seed status --json >"$TMPDIR/envleak-status.json"
    jq -e --arg cfg "$HOME/.omp/agent/config.yml" '.config == $cfg' "$TMPDIR/envleak-status.json" >/dev/null \
      || fail "status honored the profile env instead of the default root"

    # Scenario: a populated local list under a seeded empty-list key is a
    # local edit — kept and reported as drift, never overwritten.
    export HOME="$TMPDIR/listdrift"
    mkdir -p "$HOME/.omp/agent"
    config="$HOME/.omp/agent/config.yml"
    cat >"$config" <<'YAML'
    task:
      disabledAgents:
        - scout
    YAML
    atyrode-omp-seed apply >"$TMPDIR/listdrift.log"
    [ "$(yq eval '.task.disabledAgents.[0]' "$config")" = "scout" ] || fail "populated disabledAgents was overwritten by the seed"
    jq -e '.drift[] | select(.key == "task.disabledAgents")' \
      "$HOME/.local/state/atyrode/omp-plain-seed/drift.json" >/dev/null || fail "populated disabledAgents not reported as drift"

    # Scenario: a local scalar blocks seed mappings — nothing may be
    # destroyed, the blocked leaves report drift, everything else seeds.
    export HOME="$TMPDIR/blocked"
    mkdir -p "$HOME/.omp/agent"
    config="$HOME/.omp/agent/config.yml"
    state="$HOME/.local/state/atyrode/omp-plain-seed"
    cat >"$config" <<'YAML'
    task: manual-note
    dev:
      autoqa:
        consent: granted
    YAML
    atyrode-omp-seed apply >"$TMPDIR/blocked.log"
    [ "$(yq eval '.task' "$config")" = "manual-note" ] || fail "local scalar was destroyed by seeding"
    [ "$(yq eval '.dev.autoqa.consent' "$config")" = "granted" ] || fail "unmanaged key lost in blocked scenario"
    [ "$(yq eval '.secrets.enabled' "$config")" = "true" ] || fail "blocked scenario did not seed unrelated keys"
    jq -e '.drift[] | select(.key == "task.isolation.mode" and .reason == "blocked-by-local-value")' \
      "$state/drift.json" >/dev/null || fail "blocked leaf not reported as drift"
    # resolve --reset-all may displace the blocking scalar: operator choice.
    atyrode-omp-seed resolve --reset-all >"$TMPDIR/blocked-resolve.log"
    [ "$(yq eval '.task.isolation.mode' "$config")" = "auto" ] || fail "reset did not displace the blocking scalar"

    # Main flow: fresh machine with an unmanaged local key.
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/.omp/agent"
    config="$HOME/.omp/agent/config.yml"
    state="$HOME/.local/state/atyrode/omp-plain-seed"
    cat >"$config" <<'YAML'
    setupVersion: 1
    dev:
      autoqa:
        consent: granted
    YAML

    atyrode-omp-seed apply >"$TMPDIR/apply-1.log"
    grep -q 'drifted (kept)' "$TMPDIR/apply-1.log" || fail "apply produced no summary"
    [ "$(yq eval '.secrets.enabled' "$config")" = "true" ] || fail "fresh seed did not write secrets.enabled"
    [ "$(yq eval '.task.isolation.mode' "$config")" = "auto" ] || fail "fresh seed did not write task.isolation.mode"
    [ "$(yq eval '.advisor.syncBacklog' "$config")" = "3" ] || fail "fresh seed did not write advisor.syncBacklog"
    [ "$(yq eval '.dev.autoqa.consent' "$config")" = "granted" ] || fail "unmanaged key was not preserved"
    [ -f "$state/last-applied.yml" ] || fail "snapshot was not recorded"
    [ "$(jq -r '.drift | length' "$state/drift.json")" = 0 ] || fail "fresh seed reported drift"
    # Array leaves arrive intact.
    [ "$(yq eval -o=json '.retry.fallbackChains.default' "$config")" = \
      "$(yq eval -o=json '.retry.fallbackChains.default' "$seed")" ] \
      || fail "fallback chain array was not seeded verbatim"

    # Scenario: idempotent re-run.
    atyrode-omp-seed apply >"$TMPDIR/apply-2.log"
    grep -q '^omp seed: 0 applied' "$TMPDIR/apply-2.log" || fail "re-run applied changes"

    # Scenario: local edits win and are reported, including deletions.
    yq eval -i '.advisor.syncBacklog = "5"' "$config"
    yq eval -i 'del(.branchSummary.enabled)' "$config"
    atyrode-omp-seed apply >"$TMPDIR/apply-3.log"
    [ "$(yq eval '.advisor.syncBacklog' "$config")" = "5" ] || fail "local edit was overwritten"
    yq eval '.branchSummary // {} | has("enabled")' "$config" | grep -qx 'false' \
      || fail "local deletion was re-seeded"
    [ "$(jq -r '.drift | length' "$state/drift.json")" = 2 ] || fail "expected two drifted keys"
    jq -e '.drift[] | select(.key == "advisor.syncBacklog" and .reason == "local-edit")' \
      "$state/drift.json" >/dev/null || fail "edit drift not reported"
    jq -e '.drift[] | select(.key == "branchSummary.enabled" and .reason == "deleted-locally")' \
      "$state/drift.json" >/dev/null || fail "deletion drift not reported"

    # Scenario: a repository seed update follows for untouched values but
    # never for drifted ones.
    updated_seed="$TMPDIR/updated-seed.yml"
    cp "$seed" "$updated_seed"
    yq eval -i '.todo.eager = "always" | .advisor.syncBacklog = "1"' "$updated_seed"
    OMP_SEED_FILE="$updated_seed" atyrode-omp-seed apply >"$TMPDIR/apply-4.log"
    [ "$(yq eval '.todo.eager' "$config")" = "always" ] || fail "seed update was not applied"
    [ "$(yq eval '.advisor.syncBacklog' "$config")" = "5" ] || fail "seed update clobbered local edit"
    grep -q 'todo.eager' "$TMPDIR/apply-4.log" || fail "seed update was not announced"

    # Scenario: dry run writes nothing once state exists.
    before="$(sha256sum "$config" "$state/last-applied.yml" | sha256sum)"
    yq eval -i '.todo.eager = "default"' "$updated_seed"
    AGENT_TOOLS_DRY_RUN=1 OMP_SEED_FILE="$updated_seed" atyrode-omp-seed apply >"$TMPDIR/apply-dry.log"
    after="$(sha256sum "$config" "$state/last-applied.yml" | sha256sum)"
    [ "$before" = "$after" ] || fail "dry run modified state"
    grep -q 'dry run' "$TMPDIR/apply-dry.log" || fail "dry run was not announced"

    # Scenario: status --json exposes the drift, resolve --reset-all clears it.
    status_json="$(atyrode-omp-seed status --json)"
    jq -e '.drift[] | select(.key == "advisor.syncBacklog")' <<<"$status_json" >/dev/null \
      || fail "status --json misses drift"
    atyrode-omp-seed resolve --reset-all >"$TMPDIR/resolve.log"
    [ "$(yq eval '.advisor.syncBacklog' "$config")" = "3" ] || fail "reset-all did not restore the seed value"
    [ "$(yq eval '.branchSummary.enabled' "$config")" = "true" ] || fail "reset-all did not restore the deleted key"
    [ "$(jq -r '.drift | length' "$state/drift.json")" = 0 ] || fail "drift report not refreshed after resolve"

    # Scenario: interactive answers apply per key — reset the first drifted
    # key, keep the rest via keep-all, then quit paths stay safe.
    yq eval -i '.advisor.syncBacklog = "5" | .todo.eager = "default"' "$config"
    printf 'r\na\n' | atyrode-omp-seed resolve >"$TMPDIR/resolve-2.log"
    [ "$(yq eval '.advisor.syncBacklog' "$config")" = "3" ] || fail "interactive reset did not apply"
    [ "$(yq eval '.todo.eager' "$config")" = "default" ] || fail "keep-all reset a kept value"
    yq eval -i '.advisor.syncBacklog = "5"' "$config"
    printf 'k\nq\n' | atyrode-omp-seed resolve >"$TMPDIR/resolve-3.log"
    [ "$(yq eval '.advisor.syncBacklog' "$config")" = "5" ] || fail "interactive keep reset the value"

    touch "$out"
  ''
