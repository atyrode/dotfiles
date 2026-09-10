{ lib, pkgs }:

let
  fixtures = import ../lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures)
    configuredStub
    stubOmp
    ;
  # The untrusted launcher is measured by the environment and argv it hands OMP.
  envReportStubOmp =
    pkgs.runCommand "omp-env-report-stub"
      {
        inherit (stubOmp) meta;
      }
      ''
        mkdir -p "$out/bin" "$out/share/zsh/site-functions"
        cat > "$out/bin/omp" <<'EOF'
        #!${pkgs.runtimeShell}
        printf 'cwd=%s\n' "$PWD"
        printf 'HOME=%s\n' "$HOME"
        printf 'XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME"
        printf 'XDG_DATA_HOME=%s\n' "$XDG_DATA_HOME"
        printf 'XDG_STATE_HOME=%s\n' "$XDG_STATE_HOME"
        printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"
        printf 'OMP_PROFILE=%s\n' "$OMP_PROFILE"
        printf 'PI_PROFILE=%s\n' "$PI_PROFILE"
        printf 'PI_JS=%s\n' "$PI_JS"
        printf 'PI_PY=%s\n' "$PI_PY"
        printf 'OMP_WORKTREE_DIR=%s\n' "''${OMP_WORKTREE_DIR-unset}"
        printf 'PI_CONFIG_DIR=%s\n' "''${PI_CONFIG_DIR-unset}"
        printf 'PI_CODING_AGENT_DIR=%s\n' "''${PI_CODING_AGENT_DIR-unset}"
        printf 'PI_SMOL_MODEL=%s\n' "''${PI_SMOL_MODEL-unset}"
        printf 'PI_PACKAGE_DIR=%s\n' "''${PI_PACKAGE_DIR-unset}"
        printf 'OMP_AUTH_BROKER_TOKEN=%s\n' "''${OMP_AUTH_BROKER_TOKEN-unset}"
        printf 'OMP_AUTH_BROKER_ACCOUNT_POOL_FILE=%s\n' "''${OMP_AUTH_BROKER_ACCOUNT_POOL_FILE-unset}"
        printf 'ANTHROPIC_API_KEY=%s\n' "''${ANTHROPIC_API_KEY-unset}"
        printf 'OPENAI_API_KEY=%s\n' "''${OPENAI_API_KEY-unset}"
        printf 'GH_TOKEN=%s\n' "''${GH_TOKEN-unset}"
        printf 'SSH_AUTH_SOCK=%s\n' "''${SSH_AUTH_SOCK-unset}"
        printf '%s\n' '--args--' "$@"
        EOF
        chmod +x "$out/bin/omp"
        printf '#compdef omp\n' > "$out/share/zsh/site-functions/_omp"
      '';
  configuredEnvReport = pkgs.callPackage ../../pkgs/omp-configured {
    omp = envReportStubOmp;
  };
in
pkgs.runCommand "check-omp-wrapper"
  {
    nativeBuildInputs = [
      pkgs.diffutils
      pkgs.jq
      pkgs.python3
    ];
  }
  ''
        export HOME="$TMPDIR/home"
        export XDG_CONFIG_HOME="$HOME/.config"
        project="$TMPDIR/project"
        mkdir -p "$HOME/.omp/agent" "$XDG_CONFIG_HOME/omp" "$project/.omp"
        cat > "$HOME/.omp/agent/config.yml" <<'EOF'
    modelRoles:
      machine-only: machine/model:low
    EOF
        cat > "$project/.omp/settings.json" <<'EOF'
    {"modelRoles":{"default":"project/settings:low"}}
    EOF
        cat > "$project/.omp/config.yml" <<'EOF'
    modelRoles:
      default: project/model:medium
    tools:
      approvalMode: yolo
    secrets:
      enabled: false
    EOF
        cat > "$XDG_CONFIG_HOME/omp/local.yml" <<'EOF'
    custom:
      privateToken: do-not-print
    modelRoles:
      default: local/model:low
    tools:
      approvalMode: yolo
    secrets:
      enabled: false
    EOF
        cat > "$TMPDIR/managed-one-shot.yml" <<'EOF'
    modelRoles:
      default: one-shot/model:high
    tools:
      approvalMode: yolo
    secrets:
      enabled: false
    privateToken: do-not-print
    EOF
        cd "$project"

        python3 ${../../ci/check-omp-argv.py} \
          --omp ${lib.getExe pkgs.omp} \
          --managed-stub ${configuredStub}/bin/omp-managed \
          --configured ${pkgs.omp-configured} \
          --grammar ${../../pkgs/omp-configured/argv.sh}

        ${configuredStub}/bin/omp-managed \
          --config "$TMPDIR/one-shot.yml" \
          --model custom \
          -- \
          --config literal > "$TMPDIR/actual"
        cat > "$TMPDIR/expected" <<EOF
    --extension
    ${configuredStub.platformRoot}
    --config
    ${configuredStub.defaultsConfig}
    --config
    $project/.omp/settings.json
    --config
    $project/.omp/config.yml
    --config
    $XDG_CONFIG_HOME/omp/local.yml
    --config
    $TMPDIR/one-shot.yml
    --config
    ${configuredStub.policyConfig}
    --model
    custom
    --
    --config
    literal
    EOF
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        ${configuredStub}/bin/omp-managed acp \
          --config="$TMPDIR/acp-one-shot.yml" \
          --approval-mode yolo > "$TMPDIR/actual"
        cat > "$TMPDIR/expected" <<EOF
    acp
    --extension
    ${configuredStub.platformRoot}
    --config
    ${configuredStub.defaultsConfig}
    --config
    $project/.omp/settings.json
    --config
    $project/.omp/config.yml
    --config
    $XDG_CONFIG_HOME/omp/local.yml
    --config
    $TMPDIR/acp-one-shot.yml
    --config
    ${configuredStub.policyConfig}
    --config
    ${configuredStub.yoloConfig}
    --approval-mode
    yolo
    EOF
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        ${configuredStub}/bin/omp-managed models --json > "$TMPDIR/actual"
        printf 'models\n--json\n' > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        ${configuredStub}/bin/omp-managed config path > "$TMPDIR/actual"
        printf '%s\n' 'config' 'path' > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        ${configuredStub}/bin/omp-managed --no-extensions models --json > "$TMPDIR/actual"
        printf '%s\n' '--no-extensions' 'models' '--json' > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        set +e
        ${configuredStub}/bin/omp-managed --no-extensions --mode rpc \
          > "$TMPDIR/no-extensions.out" 2> "$TMPDIR/no-extensions.err"
        no_extensions_status=$?
        set -e
        test "$no_extensions_status" -eq 2

        ${configuredStub}/bin/omp-managed --resume models > "$TMPDIR/actual"
        cat > "$TMPDIR/expected" <<EOF
    --extension
    ${configuredStub.platformRoot}
    --config
    ${configuredStub.defaultsConfig}
    --config
    $project/.omp/settings.json
    --config
    $project/.omp/config.yml
    --config
    $XDG_CONFIG_HOME/omp/local.yml
    --config
    ${configuredStub.policyConfig}
    --resume
    models
    EOF
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        # Plain omp is deliberately unmanaged: every user argument passes
        # through verbatim, and only the Nix-owned update path is blocked.
        ${configuredStub}/bin/omp \
          --config "$TMPDIR/plain.yml" \
          --extension user-extension \
          --profile work \
          --resume models -- --config literal > "$TMPDIR/actual"
        cat > "$TMPDIR/expected" <<EOF
    --config
    $TMPDIR/plain.yml
    --extension
    user-extension
    --profile
    work
    --resume
    models
    --
    --config
    literal
    EOF
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"
        unset OMP_PROFILE PI_CODING_AGENT_DIR PI_CONFIG_DIR
        # A resume hint emitted by a profiled session is usable verbatim.
        resume_id=019f6386-bbf6-7000-8e5c-8d88e87e3907
        mkdir -p "$HOME/.omp/profiles/alternate/agent/sessions/-dotfiles"
        touch "$HOME/.omp/profiles/alternate/agent/sessions/-dotfiles/2026-07-15T02-06-42-166Z_$resume_id.jsonl"
        ${configuredStub}/bin/omp --resume "''${resume_id:0:12}" > "$TMPDIR/actual"
        printf '%s\n' --profile alternate --resume "''${resume_id:0:12}" > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        # Explicit state selection always wins, even when another profile
        # contains the same resume target.
        ${configuredStub}/bin/omp --profile explicit --resume "$resume_id" > "$TMPDIR/actual"
        printf '%s\n' --profile explicit --resume "$resume_id" > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        default_id=029f6386-bbf6-7000-8e5c-8d88e87e3907
        mkdir -p "$HOME/.omp/agent/sessions/-project"
        touch "$HOME/.omp/agent/sessions/-project/2026-07-15T03-00-00-000Z_$default_id.jsonl"
        ${configuredStub}/bin/omp --resume="$default_id" > "$TMPDIR/actual"
        printf '%s\n' "--resume=$default_id" > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        mkdir -p "$HOME/.omp/profiles/candidate/agent/sessions/-dotfiles"
        touch "$HOME/.omp/profiles/candidate/agent/sessions/-dotfiles/2026-07-15T04-00-00-000Z_$resume_id.jsonl"
        set +e
        ${configuredStub}/bin/omp -r"''${resume_id:0:12}" \
          > "$TMPDIR/ambiguous.out" 2> "$TMPDIR/ambiguous.err"
        ambiguous_status=$?
        set -e
        test "$ambiguous_status" -eq 2

        set +e
        ${configuredStub}/bin/omp update \
          > "$TMPDIR/plain-update.out" 2> "$TMPDIR/plain-update.err"
        plain_update_status=$?
        set -e
        test "$plain_update_status" -eq 2

        ${configuredStub}/bin/omp --help config > "$TMPDIR/actual"
        printf '%s\n' '--help' 'config' > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        ${configuredStub}/bin/omp-managed config set completion.notify off --json > "$TMPDIR/actual"
        printf '%s\n' 'config' 'set' 'completion.notify' 'off' '--json' > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/actual"

        for invocation in \
          'config set modelRoles {}' \
          'config set tools {}' \
          'config --json reset extendedContext' \
          '--profile work config set tools.approvalMode yolo' \
          'config reset secrets.enabled --json'
        do
          read -r -a args <<< "$invocation"
          set +e
          ${configuredStub}/bin/omp-managed "''${args[@]}" \
            > "$TMPDIR/refused.out" 2> "$TMPDIR/refused.err"
          refused_status=$?
          set -e
          test "$refused_status" -eq 2
        done

        ${configuredStub}/bin/omp-managed \
          --config "$TMPDIR/managed-one-shot.yml" \
          config managed --json > "$TMPDIR/managed.json"
        jq -e '.launcher == "omp-managed"' "$TMPDIR/managed.json" >/dev/null
        jq -e '.profile == "default"' "$TMPDIR/managed.json" >/dev/null
        jq -e '.statePath == $ENV.HOME + "/.omp/agent"' "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.modelRoles.default == "one-shot/model:high"' \
          "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.modelRoles["machine-only"] == "machine/model:low"' \
          "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.tools.approvalMode == "yolo"' "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.tools.approval == {
          "bash":"allow","eval":"allow","browser":"allow","task":"allow","github":"allow"
        }' "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.secrets.enabled == true' "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.task.isolation == {
          "enabled":true,"merge":"patch","commits":"generic"
        }' "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.isolation.backend == "auto"' "$TMPDIR/managed.json" >/dev/null
        jq -e '.effectiveManaged.privateToken == null' "$TMPDIR/managed.json" >/dev/null
        grep -q 'do-not-print' "$TMPDIR/managed.json" && false
        jq -e '.enforcedPolicy == {
          "tools":{"approvalMode":"yolo","approval":{
            "bash":"allow","eval":"allow","browser":"allow","task":"allow","github":"allow"
          }},
          "secrets":{"enabled":true},
          "isolation":{"backend":"auto"},
          "task":{"isolation":{"enabled":true,"merge":"patch","commits":"generic"}}
        }' \
          "$TMPDIR/managed.json" >/dev/null
        test "$(jq -r '[.sources[].kind] | join(",")' "$TMPDIR/managed.json")" = \
          'writable-machine-state,managed-defaults,native-project,native-project,machine-local,one-shot-config,managed-policy,runtime-flags'
        jq -e '.sources[0].present == true' "$TMPDIR/managed.json" >/dev/null
        jq -e --arg projectSettings "$project/.omp/settings.json" \
          '.sources[] | select(.format == "settings.json") | .path == $projectSettings and .present == true' \
          "$TMPDIR/managed.json" >/dev/null
        jq -e --arg project "$project/.omp/config.yml" \
          '.sources[] | select(.kind == "native-project") | .path == $project and .present == true' \
          "$TMPDIR/managed.json" >/dev/null
        jq -e --arg oneShot "$TMPDIR/managed-one-shot.yml" \
          '.sources[] | select(.kind == "one-shot-config") | .path == $oneShot' \
          "$TMPDIR/managed.json" >/dev/null

        # The managed launcher is a routing overlay only: it shares the
        # default profile and the normal persisted state root, so launching
        # a generated profile through it never requires re-authentication.
        ${configuredStub}/bin/omp-managed config managed --json \
          > "$TMPDIR/launcher-state.json"
        jq -e '.profile == "default"' "$TMPDIR/launcher-state.json" >/dev/null
        jq -e '.statePath == $ENV.HOME + "/.omp/agent"' \
          "$TMPDIR/launcher-state.json" >/dev/null

        PI_SMOL_MODEL=env/smol:low ${configuredStub}/bin/omp-managed \
          --approval-mode yolo \
          --model runtime/default:high \
          --smol runtime/smol:medium \
          --slow runtime/slow:xhigh \
          --plan runtime/plan:high \
          --thinking xhigh \
          --advisor \
          config managed --json > "$TMPDIR/runtime-managed.json"
        jq -e '
          .effectiveManaged.tools.approvalMode == "yolo"
          and .effectiveManaged.tools.approval.bash == "allow"
          and .effectiveManaged.tools.approval.eval == "allow"
          and .effectiveManaged.tools.approval.browser == "allow"
          and .effectiveManaged.tools.approval.task == "allow"
          and .effectiveManaged.tools.approval.github == "allow"
          and .effectiveManaged.modelRoles.default == "runtime/default:high"
          and .effectiveManaged.modelRoles.smol == "runtime/smol:medium"
          and .effectiveManaged.modelRoles.slow == "runtime/slow:xhigh"
          and .effectiveManaged.modelRoles.plan == "runtime/plan:high"
          and .effectiveManaged.defaultThinkingLevel == "xhigh"
          and .effectiveManaged.advisor.enabled == true
        ' \
          "$TMPDIR/runtime-managed.json" >/dev/null
        jq -e '.runtimeOverrides == {
          "approvalMode":"yolo",
          "model":"runtime/default:high",
          "thinking":"xhigh",
          "smol":"runtime/smol:medium",
          "slow":"runtime/slow:xhigh",
          "plan":"runtime/plan:high",
          "advisor":true,
          "unattended":true
        }' \
          "$TMPDIR/runtime-managed.json" >/dev/null
        jq -e '[.sources[].kind] | index("one-session-unattended-policy") != null' \
          "$TMPDIR/runtime-managed.json" >/dev/null

        ${configuredStub}/bin/omp-managed --yolo --mode rpc \
          > "$TMPDIR/yolo.out" 2> "$TMPDIR/yolo.err"
        grep -Fx -- '--config' "$TMPDIR/yolo.out" >/dev/null
        grep -Fx -- '${configuredStub.yoloConfig}' "$TMPDIR/yolo.out" >/dev/null

        PI_SMOL_MODEL=env/smol:low PI_SLOW_MODEL=env/slow:high PI_PLAN_MODEL=env/plan:medium \
          ${configuredStub}/bin/omp-managed config managed --json > "$TMPDIR/runtime-env.json"
        jq -e '
          .effectiveManaged.modelRoles.smol == "env/smol:low"
          and .effectiveManaged.modelRoles.slow == "env/slow:high"
          and .effectiveManaged.modelRoles.plan == "env/plan:medium"
        ' "$TMPDIR/runtime-env.json" >/dev/null

        PI_CODING_AGENT_DIR="$TMPDIR/custom-agent" \
          ${configuredStub}/bin/omp-managed config managed --json > "$TMPDIR/custom-state.json"
        jq -e --arg state "$TMPDIR/custom-agent" '.statePath == $state' \
          "$TMPDIR/custom-state.json" >/dev/null

        ${configuredStub}/bin/omp-managed --profile work \
          config managed --json > "$TMPDIR/profile-state.json"
        jq -e --arg state "$HOME/.omp/profiles/work/agent" \
          '.profile == "work" and .statePath == $state' \
          "$TMPDIR/profile-state.json" >/dev/null

        OMP_PROFILE=default PI_PROFILE=work \
          PI_CODING_AGENT_DIR="$HOME/.omp/profiles/work/agent" \
          ${configuredStub}/bin/omp-managed config managed --json > "$TMPDIR/default-profile-state.json"
        jq -e --arg state "$HOME/.omp/agent" \
          '.profile == "default" and .statePath == $state' \
          "$TMPDIR/default-profile-state.json" >/dev/null

        set +e
        ${configuredStub}/bin/omp-managed --profile ../../escape config managed --json \
          > "$TMPDIR/invalid-profile.out" 2> "$TMPDIR/invalid-profile.err"
        invalid_profile_status=$?
        set -e
        test "$invalid_profile_status" -eq 1
        grep -q 'Invalid' "$TMPDIR/invalid-profile.err"

        PI_CONFIG_DIR=.custom-omp \
          ${configuredStub}/bin/omp-managed config managed --json > "$TMPDIR/config-root.json"
        jq -e --arg state "$HOME/.custom-omp/agent" '.statePath == $state' \
          "$TMPDIR/config-root.json" >/dev/null

        yaml_home="$TMPDIR/yaml-home"
        mkdir -p "$yaml_home/.omp/agent"
        cat > "$yaml_home/.omp/agent/config.yaml" <<'EOF'
    modelRoles:
      yaml-machine: machine/yaml:low
    EOF
        HOME="$yaml_home" XDG_CONFIG_HOME="$yaml_home/.config" \
          ${configuredStub}/bin/omp-managed --cwd "$project" config managed --json \
            > "$TMPDIR/yaml-state.json"
        jq -e --arg path "$yaml_home/.omp/agent/config.yaml" '
          .sources[0].path == $path
          and .sources[0].present == true
          and .effectiveManaged.modelRoles["yaml-machine"] == "machine/yaml:low"
        ' "$TMPDIR/yaml-state.json" >/dev/null


        ${configuredStub}/bin/omp-managed --system-prompt --cwd \
          config managed --json > "$TMPDIR/arity.json"
        jq -e --arg project "$project/.omp/config.yml" \
          '.sources[] | select(.format == "config.yml") | .path == $project' \
          "$TMPDIR/arity.json" >/dev/null

        mkdir -p "$HOME/tmp/.omp" "$HOME/.omp"
        cat > "$HOME/.omp/config.yml" <<'EOF'
    modelRoles:
      workspace-role: home/project:high
    EOF
        cat > "$HOME/tmp/.omp/config.yml" <<'EOF'
    modelRoles:
      workspace-role: tmp/project:low
    EOF
        (
          cd "$HOME"
          XDG_CONFIG_HOME="$TMPDIR/auto-xdg" \
            ${configuredStub}/bin/omp-managed config managed --json > "$TMPDIR/home-auto.json"
          XDG_CONFIG_HOME="$TMPDIR/auto-xdg" \
            ${configuredStub}/bin/omp-managed --allow-home config managed --json > "$TMPDIR/home-allowed.json"
        )
        jq -e --arg cwd "$HOME/tmp" '
          .effectiveCwd == $cwd and .effectiveManaged.modelRoles["workspace-role"] == "tmp/project:low"
        ' "$TMPDIR/home-auto.json" >/dev/null
        jq -e --arg cwd "$HOME" '
          .effectiveCwd == $cwd and .effectiveManaged.modelRoles["workspace-role"] == "home/project:high"
        ' "$TMPDIR/home-allowed.json" >/dev/null

        current_project="$TMPDIR/current-project"
        mkdir -p "$current_project/.omp"
        cat > "$current_project/.omp/config.yml" <<'EOF'
    theme:
      dark: custom-dark
    codexResets:
      autoRedeem: "yes"
    memory:
      backend: "off"
    EOF
        cat > "$current_project/relative.yml" <<'EOF'
    modelRoles:
      default: relative/one-shot:high
    EOF
        ${configuredStub}/bin/omp-managed \
          --cwd "$current_project" \
          --config relative.yml \
          config managed --json > "$TMPDIR/current-managed.json"
        jq -e --arg oneShot "$current_project/relative.yml" '
          .effectiveManaged.theme.dark == "custom-dark"
          and .effectiveManaged.codexResets.autoRedeem == "yes"
          and .effectiveManaged.memory.backend == "off"
          and .effectiveManaged.modelRoles.default == "relative/one-shot:high"
          and (.sources[] | select(.kind == "one-shot-config") | .path == $oneShot)
        ' "$TMPDIR/current-managed.json" >/dev/null

        # Legacy sources still load; the real pinned resolver owns migration.
        # This also checks that inspection does not rewrite the source.
        legacy_project="$TMPDIR/legacy-project"
        mkdir -p "$legacy_project/.omp"
        cat > "$legacy_project/.omp/config.yml" <<'EOF'
    theme: custom-dark
    codexResets:
      autoRedeem: true
    memories:
      enabled: false
    EOF
        cp "$legacy_project/.omp/config.yml" "$TMPDIR/legacy-before.yml"
        ${configuredStub}/bin/omp-managed \
          --cwd "$legacy_project" \
          config managed --json > "$TMPDIR/legacy-managed.json"
        jq -e '
          .effectiveManaged.theme.dark == "custom-dark"
          and .effectiveManaged.codexResets.autoRedeem == "yes"
          and .effectiveManaged.memory.backend == "off"
        ' "$TMPDIR/legacy-managed.json" >/dev/null
        cmp "$legacy_project/.omp/config.yml" "$TMPDIR/legacy-before.yml"

        # Native schema fallback after an explicit null is not a JSON merge.
        printf 'theme:\n  dark: null\n' > "$TMPDIR/null-overlay.yml"
        ${configuredStub}/bin/omp-managed --cwd "$legacy_project" \
          --config "$TMPDIR/null-overlay.yml" config managed --json > "$TMPDIR/null-managed.json"
        mkdir -p "$TMPDIR/native-cwd"
        (
          cd "$TMPDIR/native-cwd"
          HOME="$TMPDIR/native-home" PI_CODING_AGENT_DIR="$TMPDIR/native-agent" \
            PI_CONFIG_FILES="$legacy_project/.omp/config.yml:$TMPDIR/null-overlay.yml" \
            ${lib.getExe pkgs.omp} config list --json > "$TMPDIR/native-config.json"
        )
        jq -e --slurpfile native "$TMPDIR/native-config.json" \
          '.effectiveManaged.theme.dark == $native[0]["theme.dark"].value' \
          "$TMPDIR/null-managed.json" >/dev/null

        # Colons are valid filenames, not extra PI_CONFIG_FILES separators.
        cp "$TMPDIR/managed-one-shot.yml" "$TMPDIR/overlay:colon.yml"
        ${configuredStub}/bin/omp-managed --config "$TMPDIR/overlay:colon.yml" \
          config managed --json > "$TMPDIR/colon-managed.json"
        jq -e '.effectiveManaged.modelRoles.default == "one-shot/model:high"' \
          "$TMPDIR/colon-managed.json" >/dev/null

        # Native errors can contain YAML source snippets. The public diagnostic
        # fails without leaking those bytes or mutating a malformed source.
        printf 'theme: [secret-diagnostic-canary\n' > "$TMPDIR/bad.yml"
        cp "$TMPDIR/bad.yml" "$TMPDIR/bad-before.yml"
        if ${configuredStub}/bin/omp-managed --config "$TMPDIR/bad.yml" \
          config managed --json > "$TMPDIR/bad.out" 2> "$TMPDIR/bad.err"; then
          exit 1
        fi
        ! grep -q 'secret-diagnostic-canary' "$TMPDIR/bad.out" "$TMPDIR/bad.err"
        cmp "$TMPDIR/bad.yml" "$TMPDIR/bad-before.yml"

        printf 'modelRoles:\n  env-only: env/model:low\n' > "$TMPDIR/env-config.yml"
        PI_CONFIG_FILES="$TMPDIR/env-config.yml" ${configuredStub}/bin/omp-managed \
          config managed --json > "$TMPDIR/env-config.json"
        jq -e '.effectiveManaged.modelRoles["env-only"] == "env/model:low"
          and any(.sources[]; .kind == "environment-config")' "$TMPDIR/env-config.json" >/dev/null

        set +e
        ${configuredStub}/bin/omp-managed config get modelRoles --json \
          > "$TMPDIR/get.out" 2> "$TMPDIR/get.err"
        get_status=$?
        set -e
        test "$get_status" -eq 2

        ${configuredStub}/bin/omp-managed config list > "$TMPDIR/list.out" 2> "$TMPDIR/list.err"
        printf '%s\n' config list > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/list.out"

        ${configuredStub}/bin/omp-managed setup --help > "$TMPDIR/setup.out" 2> "$TMPDIR/setup.err"
        printf '%s\n' setup --help > "$TMPDIR/expected"
        diff -u "$TMPDIR/expected" "$TMPDIR/setup.out"

        # Plain omp is unmanaged and has no Nix-declared default model;
        # the managed launcher pins the managed defaults' routing (asserted
        # directly with yq above).
        policy_home="$TMPDIR/policy-home"
        policy_project="$TMPDIR/policy-project"
        mkdir -p "$policy_home" "$policy_project"
        HOME="$policy_home" XDG_CONFIG_HOME="$policy_home/.config" \
          ${configuredStub}/bin/omp-managed --cwd "$policy_project" \
            config managed --json > "$TMPDIR/managed-policy.json"
        jq -e '.effectiveManaged.modelRoles.default == "openai-codex/gpt-5.6-sol:medium"' \
          "$TMPDIR/managed-policy.json" >/dev/null
        jq -e '.effectiveManaged.retry.modelFallback == true' \
          "$TMPDIR/managed-policy.json" >/dev/null

        for command in omp omp-managed; do
          set +e
          ${configuredStub}/bin/"$command" update \
            > "$TMPDIR/update.out" 2> "$TMPDIR/update.err"
          update_status=$?
          set -e
          test "$update_status" -eq 2
        done

        untrusted_home="$TMPDIR/untrusted-home"
        untrusted_project="$TMPDIR/untrusted-project"
        mkdir -p "$untrusted_home" "$untrusted_project/.omp"
        cat > "$untrusted_project/.omp/settings.json" <<'EOF'
    {"tools":{"approvalMode":"yolo"},"secrets":{"enabled":false}}
    EOF
        cat > "$untrusted_project/.omp/config.yml" <<'EOF'
    tools:
      approvalMode: yolo
      approval:
        browser: allow
        github: allow
        eval: allow
    secrets:
      enabled: false
    mcp:
      enableProjectConfig: true
    task:
      isolation:
        mode: none
    EOF
        HOME="$untrusted_home" \
          OPENAI_API_KEY=must-not-cross-boundary \
          GH_TOKEN=must-not-cross-boundary \
          SSH_AUTH_SOCK="$TMPDIR/agent.sock" \
          ${configuredEnvReport}/bin/ompu \
            --cwd "$untrusted_project" --mode rpc --no-session \
            > "$TMPDIR/untrusted.out"
        grep -Fx "cwd=${configuredEnvReport.neutralRoot}" "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx "HOME=$untrusted_home/.local/state/atyrode/omp-untrusted/home" \
          "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'OMP_PROFILE=untrusted' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'PI_PROFILE=untrusted' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'PI_JS=0' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'PI_PY=0' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'OPENAI_API_KEY=unset' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'GH_TOKEN=unset' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx 'SSH_AUTH_SOCK=unset' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx '${configuredEnvReport.untrustedConfig}' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx "$untrusted_project/.omp/settings.json" "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx "$untrusted_project/.omp/config.yml" "$TMPDIR/untrusted.out" >/dev/null
        test "$(grep -nFx '${configuredEnvReport.untrustedConfig}' "$TMPDIR/untrusted.out" | cut -d: -f1)" \
          -gt "$(grep -nFx "$untrusted_project/.omp/config.yml" "$TMPDIR/untrusted.out" | cut -d: -f1)"
        grep -Fx -- '--no-lsp' "$TMPDIR/untrusted.out" >/dev/null
        grep -Fx -- '--no-pty' "$TMPDIR/untrusted.out" >/dev/null

        for unsafe in '--yolo' '--yolo=false' '--auto-approve=false' '--approval-mode yolo' \
          '--config attacker.yml' '--no-extensions' '--no-extensions=false' \
          '--trusted-extension /tmp/ext' '--add-dir /tmp/elsewhere' \
          '--continue=false' '--from-codex' '-r0123456789ab'; do
          read -r -a args <<< "$unsafe"
          set +e
          HOME="$untrusted_home" ${configuredEnvReport}/bin/ompu "''${args[@]}" \
            > "$TMPDIR/untrusted-refused.out" 2> "$TMPDIR/untrusted-refused.err"
          untrusted_refused_status=$?
          set -e
          test "$untrusted_refused_status" -eq 2
        done

        HOME="$untrusted_home" ${configuredEnvReport}/bin/ompu --cwd "$untrusted_project" \
          --model --no-extensions --service-tier --config -- --yolo \
          > "$TMPDIR/untrusted-values.out"
        grep -Fx -- '--no-extensions' "$TMPDIR/untrusted-values.out" >/dev/null
        grep -Fx -- '--config' "$TMPDIR/untrusted-values.out" >/dev/null
        grep -Fx -- '--yolo' "$TMPDIR/untrusted-values.out" >/dev/null

        mkdir -p "$untrusted_project/.omp/extensions"
        set +e
        HOME="$untrusted_home" ${configuredEnvReport}/bin/ompu --cwd "$untrusted_project" \
          > "$TMPDIR/untrusted-project.out" 2> "$TMPDIR/untrusted-project.err"
        executable_project_status=$?
        set -e
        test "$executable_project_status" -eq 2


        mkdir "$out"
  ''
