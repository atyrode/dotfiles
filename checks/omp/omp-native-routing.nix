{ pkgs }:

let
  commonConfig = ''
    enabledModels:
      - native-routing-fixture/*
    defaultThinkingLevel: low
    async:
      enabled: false
    advisor:
      enabled: false
    autolearn:
      enabled: false
    branchSummary:
      enabled: false
    checkpoint:
      enabled: false
    compaction:
      asyncEnabled: false
    recap:
      enabled: false
    memory:
      backend: off
    stt:
      enabled: false
    startup:
      checkUpdate: false
    todo:
      enabled: false
    task:
      batch: false
      structured: true
      prewalk: false
      maxRuntimeMs: 30000
      disabledAgents: []
    tools:
      approvalMode: yolo
  '';
  gridConfig = pkgs.writeText "omp-native-routing-grid.yml" (
    commonConfig
    + ''
      retry:
        enabled: false
        usageAwareFallback: false
        fallbackChains:
          widget: []
          tiny: []
          memory: []
      modelRoles:
        default: native-routing-fixture/default:medium
        task: native-routing-fixture/task:medium
        smol: native-routing-fixture/smol:medium
        slow: native-routing-fixture/slow:high
        plan: native-routing-fixture/slow:high
        advisor: native-routing-fixture/smol:low
        tiny: native-routing-fixture/smol:low
        commit: native-routing-fixture/smol:low
        vision: native-routing-fixture/smol:low
        widget: native-routing-fixture/smol:low
        memory: native-routing-fixture/smol:medium
    ''
  );
  retryConfig = pkgs.writeText "omp-native-routing-retry.yml" (
    commonConfig
    + ''
      modelRoles:
        default: native-routing-fixture/lead:medium
        task: native-routing-fixture/lead:medium
        slow: native-routing-fixture/lead:medium
        smol: native-routing-fixture/lead:medium
        plan: native-routing-fixture/lead:medium
        advisor: native-routing-fixture/lead:medium
        tiny: native-routing-fixture/smol:low
        commit: native-routing-fixture/lead:medium
        vision: native-routing-fixture/lead:medium
        widget: native-routing-fixture/smol:low
        memory: native-routing-fixture/smol:medium
      retry:
        enabled: true
        maxRetries: 1
        baseDelayMs: 1
        maxDelayMs: 100
        modelFallback: true
        fallbackOn: any
        fallbackRevertPolicy: never
        usageAwareFallback: false
        waitForUsageReset: false
        fallbackChains:
          default:
            - native-routing-fixture/default-fallback:medium
          task:
            - native-routing-fixture/task-fallback:medium
          slow:
            - native-routing-fixture/slow-fallback:medium
          smol: []
          plan: []
          advisor: []
          tiny: []
          commit: []
          vision: []
          widget: []
          memory: []
    ''
  );
in
pkgs.runCommand "check-omp-native-routing"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gitMinimal
      pkgs.jq
    ];
  }
  ''
    # Use the real pinned binary and the real managed launcher independently.
    # Only model inference is scripted; native discovery, task, schemas, saved
    # sessions, effort selection and retry recovery remain in the runtime.
    # No agents directory, prompt replacement, model override or per-call model
    # selector is installed. agentSource below also detects same-name shadows.
    mkdir "$out"
    fixture="$TMPDIR/native-routing"
    mkdir -m 700 "$fixture"
    trap 'rm -rf "$fixture"' EXIT

    dump_evidence() {
      if [ -f "$trace" ]; then cat "$trace" >&2; fi
      for results in "$trace".*-results.json; do
        if [ -f "$results" ]; then
          printf '\nNative task results: %s\n' "$results" >&2
          cat "$results" >&2
          printf '\n' >&2
        fi
      done
    }

    assert_json() {
      local label="$1"
      shift
      if ! jq -e "$@" >/dev/null; then
        printf 'Native routing assertion failed: %s (%s)\n' "$label" "$launcher_name" >&2
        dump_evidence
        exit 1
      fi
    }

    run_omp() {
      local label="$1"
      shift
      # A clean environment and disposable HOME deny operator credentials,
      # profiles, account pools and project/user extensions. The extension's
      # fetch guard and the Nix build sandbox deny remote inference as well.
      if ! env -i \
        HOME="$home" PATH="$PATH" TMPDIR="$TMPDIR" \
        XDG_CONFIG_HOME="$home/config" XDG_CACHE_HOME="$home/cache" \
        XDG_DATA_HOME="$home/data" XDG_STATE_HOME="$home/state" \
        TERM=dumb LANG=C.UTF-8 PI_BASH_NO_LOGIN=1 \
        OMP_NATIVE_ROUTING_OBSERVATION="$trace" \
        OMP_NATIVE_ROUTING_SOURCE_SESSION="''${source_session:-}" \
        timeout 240 "$launcher" \
          --cwd "$project" --no-lsp --no-title --print "$@" \
          > "$fixture/$launcher_name-$label.out" \
          2> "$fixture/$launcher_name-$label.err"; then
        cat "$fixture/$launcher_name-$label.out" "$fixture/$launcher_name-$label.err" >&2
        dump_evidence
        exit 1
      fi
    }

    for launcher_name in native managed; do
      case "$launcher_name" in
        native) launcher=${pkgs.omp}/bin/omp ;;
        managed) launcher=${pkgs.omp-configured}/bin/omp-managed ;;
      esac
      home="$fixture/$launcher_name-home"
      project="$fixture/$launcher_name-project"
      trace="$out/$launcher_name-calls.jsonl"
      source_sessions="$fixture/$launcher_name-source-sessions"
      source_session=""
      mkdir -p "$home" "$project/.omp/extensions" "$source_sessions"
      cp ${./omp-native-routing-provider.ts} "$project/.omp/extensions/native-routing-fixture.ts"
      cp ${gridConfig} "$project/.omp/config.yml"

      # A real saved session, with a model and effort different from both main
      # and default. Native seance restores this source, not its caller's model.
      run_omp source \
        --model native-routing-fixture/archive --thinking xhigh \
        --session-dir "$source_sessions" \
        'OMP_NATIVE_ROUTING:source:parent'
      sessions=( "$source_sessions"/*.jsonl )
      test "''${#sessions[@]}" -eq 1
      test -f "''${sessions[0]}"
      source_session="''${sessions[0]}"

      run_omp grid \
        --model native-routing-fixture/main --thinking max --no-session \
        'OMP_NATIVE_ROUTING:grid:parent'

      # Compare actual provider calls, not aliases, config rendering, source
      # strings or version text. Every continuation must retain its effort.
      # Security inherits main's active model, but a fresh child's effort is
      # the configured session default (low), not main's CLI-only max.
      assert_json 'six native child model/effort choices' -s '
        def calls($agent): [.[] | select(.scenario == "grid" and .kind == "child" and .agent == $agent)];
        . as $all
        | {
            task: ["task", "medium"],
            scout: ["smol", "medium"],
            sonic: ["smol", "medium"],
            reviewer: ["slow", "high"],
            "security-reviewer": ["main", "low"],
            seance: ["archive", "xhigh"]
          }
        | to_entries
        | all(.[]; . as $expected
            | ($all | calls($expected.key)) as $calls
            | ($calls | length > 0)
              and all($calls[];
                .provider == "native-routing-fixture"
                and [.model, .thinking] == $expected.value))
      ' "$trace"
      assert_json 'main max control and persisted source effort' -s '
        any(.[]; .scenario == "grid" and .agent == "parent" and .model == "main" and .thinking == "max")
        and any(.[]; .scenario == "source" and .model == "archive" and .thinking == "xhigh")
      ' "$trace"
      # Native task UI labels are separate tiny-role requests with no tools;
      # they are not widget requests or child turns. Native utility inference
      # forces reasoning off, so the observed effort is null, not role low.
      assert_json 'auxiliary tiny labels remain cheap with reasoning disabled' -s '
        any(.[]; .scenario == "grid" and .kind == "auxiliary")
        and all(.[] | select(.kind == "auxiliary");
          .provider == "native-routing-fixture" and .model == "smol"
          and .thinking == null and .disableReasoning == true and .tools == [])
      ' "$trace"
      assert_json 'task keeps native full tools; specialists stay read-only' -s '
        def child($name): [.[] | select(.scenario == "grid" and .kind == "child" and .agent == $name)];
        (child("task") | all(.[]; (.tools | index("write")) != null and (.tools | index("bash")) != null))
        and all(.[] | select(.scenario == "grid" and .kind == "child" and (.agent == "scout" or .agent == "security-reviewer" or .agent == "seance"));
          (.tools | index("write")) == null and (.tools | index("bash")) == null)
        and (child("seance") | all(.[]; .tools == ["glob", "grep", "read", "yield"]))
      ' "$trace"
      assert_json 'six bundled identities complete without schema overrides' '
        length == 6
        and all(.[]; (.isError | not) and (.details.results | length == 1))
        and ([.[].details.results[0].agent] | sort) == ["reviewer", "scout", "seance", "security-reviewer", "sonic", "task"]
        and all(.[].details.results[0];
          .agentSource == "bundled" and .exitCode == 0 and (.error == null) and (.aborted != true)
          and all(.extractedToolData.yield[]?; .schemaOverridden != true))
        and all(.[].details.results[0] | select(.agent == "reviewer" or .agent == "scout" or .agent == "security-reviewer");
          .structuredOutput.source == "agent" and .structuredOutput.mode == "strict" and .structuredOutput.status == "valid")
        and any(.[].details.results[0]; .agent == "reviewer" and .structuredOutput.data.overall_correctness == "correct")
        and any(.[].details.results[0]; .agent == "security-reviewer" and .structuredOutput.data.findings == [])
      ' "$trace.grid-results.json"

      # Genuine retry oracle: task/slow/smol AND default share one lead and
      # effort. Distinct fallbacks make role loss observable at the provider;
      # an explicitly empty smol chain must fail, not borrow another role.
      cp ${retryConfig} "$project/.omp/config.yml"
      run_omp retry \
        --model native-routing-fixture/lead --thinking medium --no-session \
        'OMP_NATIVE_ROUTING:retry:parent'
      assert_json 'retry uses each native role own fallback' -s '
        def calls($agent): [.[] | select(.scenario == "retry" and .kind == "child" and .agent == $agent)];
        def route($agent): calls($agent) | map(.model)
          | reduce .[] as $model ([]; if .[-1] == $model then . else . + [$model] end);
        (route("task") == ["lead", "task-fallback"])
        and (route("reviewer") == ["lead", "slow-fallback"])
        and (calls("scout") | length > 0 and all(.[]; .model == "lead"))
        and all(.[] | select(.scenario == "retry" and .kind != "auxiliary"); .thinking == "medium")
        and all(.[] | select(.scenario == "retry" and .kind == "child"); .model != "default-fallback")
        and all(.[] | select(.scenario == "retry" and .kind == "auxiliary");
          .provider == "native-routing-fixture" and .model == "smol"
          and .thinking == null and .disableReasoning == true and .tools == [])
      ' "$trace"
      assert_json 'own chains succeed; explicit empty chain surfaces failure' '
        length == 3
        and all(.[]; .details.results | length == 1)
        and all(.[].details.results[0]; .agentSource == "bundled")
        and all(.[].details.results[0] | select(.agent == "task" or .agent == "reviewer");
          .exitCode == 0 and (.error == null) and .resolvedModelIsFallback == true)
        and any(.[].details.results[0]; .agent == "scout" and (.exitCode != 0 or .error != null))
        and any(.[].details.results[0]; .agent == "reviewer" and .structuredOutput.status == "valid")
      ' "$trace.retry-results.json"
    done
  ''
