{
  hostConfigs,
  lib,
  pkgs,
}:

let
  # The headless x86_64 baseline is where the herdr server hosts OMP panes;
  # the Mac host is the thin client attaching over SSH. Remote attach only
  # reuses the server-side Nix binary (~/.nix-profile/bin/herdr is in herdr's
  # candidate list) when both sides run the same pinned version, so both
  # hosts must carry the one pin and the one managed config.
  server = hostConfigs.alex-x86_64-linux.config;
  client = hostConfigs.alex-aarch64-darwin.config;
  herdrConfig = server.xdg.configFile."herdr/config.toml".text;
  serverPackages = map lib.getName server.home.packages;
  clientPackages = map lib.getName client.home.packages;
  vendoredSkill = builtins.readFile ../agents/skills/herdr/SKILL.md;
  renderedConfig = pkgs.writeText "herdr-config.toml" herdrConfig;
  usagePublisher = server.systemd.user.services.atyrode-herdr-usage-publisher;
in
assert lib.assertMsg (builtins.elem "herdr" serverPackages)
  "the headless Linux baseline must carry the pinned herdr server (#269)";
assert lib.assertMsg (builtins.elem "herdr" clientPackages)
  "the Mac host must carry the pinned herdr thin client (#269)";
assert lib.assertMsg (
  client.xdg.configFile."herdr/config.toml".text == herdrConfig
) "herdr client and server must share one managed config";
assert lib.assertMsg (
  server.home.activation ? seedHerdrOmpIntegration
) "activation must seed the herdr OMP integration (home/herdr.nix)";
assert lib.assertMsg (
  !(client.systemd.user.services ? atyrode-herdr-usage-publisher)
) "the herdr usage publisher must remain Linux-only";
assert lib.assertMsg (
  usagePublisher.Service.Restart == "on-failure"
  && !(usagePublisher ? Install && usagePublisher.Install ? WantedBy)
) "the Linux herdr usage publisher must stay dormant (manual start only) during the fork phase";
assert lib.assertMsg (lib.hasSuffix "/bin/atyrode-herdr-usage-publisher" (
  toString usagePublisher.Service.ExecStart
)) "the usage publisher unit must exec the wrapped repository script";
assert lib.assertMsg
  (lib.hasInfix "HERDR_SKILL_UPSTREAM_VERSION=${pkgs.herdr.version}" vendoredSkill)
  "agents/skills/herdr/SKILL.md lags the pkgs/herdr pin ${pkgs.herdr.version}: review the upstream SKILL.md diff at the new tag, refresh the vendored copy, and update its HERDR_SKILL_UPSTREAM_VERSION marker";
pkgs.runCommand "check-herdr"
  {
    nativeBuildInputs = [
      pkgs.herdr
      pkgs.jq
      pkgs.taplo
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    # Syntax-check the repository script directly: interpolating the unit's
    # ExecStart here would drag the fixed x86_64 host's closure (and its
    # platform-locked herdr asset) into every platform's check build. The
    # unit itself is pinned by the eval assertions above.
    bash -n ${../scripts/herdr-usage-publisher.sh}

    # The pinned asset must run on this platform and report the pinned
    # version — a wrong asset/hash pairing or a broken download dies here.
    herdr --version | grep -qx "herdr ${pkgs.herdr.version}"

    # The managed config must parse: herdr falls back to ALL defaults on a
    # TOML parse error (config/io.rs), which would resurrect the first-run
    # wizard against the read-only store link. Re-assert every guarded knob
    # through a real TOML parser instead of substring matching.
    [ "$(taplo get -f ${renderedConfig} 'onboarding')" = false ]
    [ "$(taplo get -f ${renderedConfig} 'session.resume_agents_on_restore')" = true ]
    [ "$(taplo get -f ${renderedConfig} 'update.version_check')" = false ]
    [ "$(taplo get -f ${renderedConfig} 'update.manifest_check')" = false ]
    [ "$(taplo get -f ${renderedConfig} 'experimental.pane_history')" = false ]
    [ "$(taplo get -f ${renderedConfig} 'remote.manage_ssh_config')" = true ]
    [ "$(taplo get -f ${renderedConfig} 'ui.agent_panel_sort')" = priority ]
    [ "$(taplo get -f ${renderedConfig} 'ui.toast.delivery')" = herdr ]
    if taplo get -f ${renderedConfig} 'ui.sidebar' >/dev/null 2>&1; then
      echo "sidebar row overrides were retired with the terse usage rows" >&2
      exit 1
    fi
    # Formatter contract, deterministically: run the repository script (the
    # wrapped unit bakes store curl/herdr into PATH, so stubs target the
    # bare names the repo script calls) against stub brokers and a stub
    # herdr CLI, and pin the glyph-fused positional grammar plus its
    # 21-cell worst case — the width the managed 28-column sidebar
    # guarantees behind the indented-row prefix and scrollbar column.
    fixtures="$TMPDIR/fixtures"
    mkdir -p "$fixtures/bin" "$fixtures/xdg/herdr/sessions/smoke"
    touch "$fixtures/xdg/herdr/sessions/smoke/herdr.sock"
    printf 'sekret-bearer-123\n' > "$fixtures/token"
    printf '[{"id":"main","brokerUrl":"http://127.0.0.1:1","tokenFile":"%s"}]\n' \
      "$fixtures/token" > "$fixtures/manifest.json"

    cat > "$fixtures/bin/curl" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "''${CURL_ARGS_LOG:?}"
    cat > /dev/null  # consume the --config stdin without logging it
    cat "''${CURL_FIXTURE:?}"
    EOF
    cat > "$fixtures/bin/herdr" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "''${HERDR_ARGS_LOG:?}"
    case "$1 $2" in
      'pane list') printf '{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent":"omp","tokens":{"vault_broker":"http://127.0.0.1:1"}}]}}\n' ;;
      'workspace list') printf '{"result":{"workspaces":[{"workspace_id":"w1"}]}}\n' ;;
      *) : ;;
    esac
    EOF
    chmod +x "$fixtures/bin/curl" "$fixtures/bin/herdr"

    run_publisher() {
      env PATH="$fixtures/bin:$PATH" \
        HERDR_USAGE_PUBLISHER_ONCE=1 \
        XDG_CONFIG_HOME="$fixtures/xdg" \
        CODE_AUTH_VAULTS_FILE="$fixtures/manifest.json" \
        CODE_AUTH_STATE="$fixtures/absent-state.json" \
        CURL_FIXTURE="$1" CURL_ARGS_LOG="$2" HERDR_ARGS_LOG="$3" \
        bash ${../scripts/herdr-usage-publisher.sh}
    }

    # Worst case: every window saturated. Exactly 21 cells, never truncated.
    cat > "$fixtures/worst.json" <<'EOF'
    {"reports":[
      {"provider":"anthropic","limits":[
        {"label":"5-hour","scope":{"tier":"-"},"amount":{"usedFraction":1},"window":{"durationMs":18000000}},
        {"label":"7-day","scope":{"tier":"-"},"amount":{"usedFraction":1},"window":{"durationMs":604800000}},
        {"label":"7-day fable","scope":{"tier":"fable"},"amount":{"usedFraction":1},"window":{"durationMs":604800000}}]},
      {"provider":"openai-codex","limits":[
        {"label":"5-hour","scope":{"tier":"-"},"amount":{"usedFraction":1},"window":{"durationMs":18000000}},
        {"label":"7-day","scope":{"tier":"-"},"amount":{"usedFraction":1},"window":{"durationMs":604800000}}]}
    ]}
    EOF
    run_publisher "$fixtures/worst.json" "$fixtures/curl-worst.log" "$fixtures/herdr-worst.log"
    grep -Fq -- '--token usage=C100 100/100 X100 100' "$fixtures/herdr-worst.log" \
      || { echo 'worst-case grammar drifted' >&2; cat "$fixtures/herdr-worst.log" >&2; exit 1; }
    worst_line='C100 100/100 X100 100'
    [ "''${#worst_line}" -le 21 ]

    # Typical case: idle Claude 5h, missing Codex 5h renders the positional
    # placeholder, fable rides the 7d slot.
    cat > "$fixtures/typical.json" <<'EOF'
    {"reports":[
      {"provider":"anthropic","limits":[
        {"label":"5-hour","scope":{"tier":"-"},"amount":{"usedFraction":0},"window":{"durationMs":18000000}},
        {"label":"7-day","scope":{"tier":"-"},"amount":{"usedFraction":0.45},"window":{"durationMs":604800000}},
        {"label":"7-day fable","scope":{"tier":"fable"},"amount":{"usedFraction":0.8},"window":{"durationMs":604800000}}]},
      {"provider":"openai-codex","limits":[
        {"label":"7-day","scope":{"tier":"-"},"amount":{"usedFraction":0.27},"window":{"durationMs":604800000}},
        {"label":"spark","scope":{"tier":"spark"},"amount":{"usedFraction":0.9},"window":{"durationMs":604800000}}]}
    ]}
    EOF
    run_publisher "$fixtures/typical.json" "$fixtures/curl-typical.log" "$fixtures/herdr-typical.log"
    grep -Fq -- '--token usage=C0 45/80 X- 27' "$fixtures/herdr-typical.log" \
      || { echo 'typical grammar drifted (spark must stay hidden)' >&2; cat "$fixtures/herdr-typical.log" >&2; exit 1; }

    # The bearer token must never reach any process argv.
    if grep -rq 'sekret-bearer-123' "$fixtures"/curl-*.log "$fixtures"/herdr-*.log; then
      echo 'bearer token leaked into stub argv' >&2
      exit 1
    fi

    # The activation seed's real contract, under a scratch agent dir: the
    # installer must write the version-stamped extension exactly where OMP
    # auto-discovers it, at or above the native session-restore minimum
    # (integration version 3, #269).
    export PI_CODING_AGENT_DIR="$TMPDIR/agent"
    mkdir -p "$PI_CODING_AGENT_DIR/extensions"
    herdr integration install omp
    extension="$PI_CODING_AGENT_DIR/extensions/herdr-omp-agent-state.ts"
    test -f "$extension"
    grep -q '^// HERDR_INTEGRATION_ID=omp$' "$extension"
    stamped="$(grep -oE 'HERDR_INTEGRATION_VERSION=[0-9]+' "$extension" | grep -oE '[0-9]+$')"
    test "$stamped" -ge 3
    herdr integration status | grep -q '^omp: current'

    # Uninstall must stay scoped to the one managed file.
    touch "$PI_CODING_AGENT_DIR/extensions/unrelated.ts"
    herdr integration uninstall omp
    test ! -e "$extension"
    test -f "$PI_CODING_AGENT_DIR/extensions/unrelated.ts"

    mkdir "$out"
  ''
