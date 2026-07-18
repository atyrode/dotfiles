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
    [ "$(taplo get -f ${renderedConfig} 'ui.sidebar.sections[0].id')" = usage ]
    [ "$(taplo get -f ${renderedConfig} 'ui.sidebar.sections[0].title')" = usage ]
    [ "$(taplo get -f ${renderedConfig} 'ui.sidebar.sections[0].max_rows')" = 18 ]
    [ "$(taplo get -f ${renderedConfig} 'ui.sidebar.sections[0].placement')" = below_agents ]
    if taplo get -f ${renderedConfig} 'ui.sidebar.spaces' >/dev/null 2>&1 ||
      taplo get -f ${renderedConfig} 'ui.sidebar.agents' >/dev/null 2>&1; then
      echo "spaces/agents row overrides were retired with the terse usage rows" >&2
      exit 1
    fi

    # End-to-end section contract: two enabled vault brokers share one Codex
    # identity but carry distinct Claude identities. Stubs keep the live herdr
    # session untouched while exercising socket discovery, per-URL broker
    # reads, stdin-only section publication, account grouping, and styling.
    fixtures="$TMPDIR/fixtures"
    mkdir -p "$fixtures/bin" "$fixtures/xdg/herdr/sessions/smoke"
    touch "$fixtures/xdg/herdr/sessions/smoke/herdr.sock"
    printf 'sekret-bearer-alpha\n' > "$fixtures/token-alpha"
    printf 'sekret-bearer-beta\n' > "$fixtures/token-beta"
    chmod 0600 "$fixtures/token-alpha" "$fixtures/token-beta"

    cat > "$fixtures/manifest.json" <<EOF
    [
      {
        "id": "alpha",
        "label": "alpha",
        "brokerUrl": "http://127.0.0.1:41001",
        "tokenFile": "$fixtures/token-alpha"
      },
      {
        "id": "beta",
        "label": "beta",
        "brokerUrl": "http://127.0.0.1:41002",
        "tokenFile": "$fixtures/token-beta"
      }
    ]
    EOF
    printf '%s\n' '{"selected":"alpha","disabled":[]}' > "$fixtures/vault-state.json"

    cat > "$fixtures/alpha-snapshot.json" <<'EOF'
    {"credentials":[
      {
        "provider":"anthropic",
        "identityKey":"email:claude.alpha@example.test",
        "credential":{"email":"claude.alpha@example.test","access":"snapshot-secret-alpha"}
      },
      {
        "provider":"openai-codex",
        "identityKey":"email:shared.codex@example.test",
        "credential":{"email":"Shared.Codex@Example.Test","refresh":"snapshot-secret-codex"}
      }
    ]}
    EOF
    cat > "$fixtures/beta-snapshot.json" <<'EOF'
    {"credentials":[
      {
        "provider":"anthropic",
        "identityKey":"email:claude.beta@example.test",
        "credential":{"email":"claude.beta@example.test","access":"snapshot-secret-beta"}
      },
      {
        "provider":"openai-codex",
        "identityKey":"email:shared.codex@example.test",
        "credential":{"email":"Shared.Codex@Example.Test","refresh":"snapshot-secret-codex"}
      }
    ]}
    EOF

    # The fixed epoch (1700000000000 ms) is supplied by the date stub below.
    # Input order is deliberately scrambled; output order is part of the
    # contract. Alpha carries fable plus both Spark durations.
    cat > "$fixtures/alpha-usage.json" <<'EOF'
    {"reports":[
      {
        "provider":"openai-codex",
        "metadata":{"email":"shared.codex@example.test"},
        "limits":[
          {
            "label":"7 day",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.12},
            "window":{"id":"7d","durationMs":604800000}
          },
          {
            "label":"Spark 7 Day",
            "scope":{"tier":"spark"},
            "amount":{"usedFraction":0.67},
            "window":{"durationMs":604800000,"resetsAt":1700273600000}
          },
          {
            "label":"5 hour",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.23},
            "window":{"durationMs":18000000,"resetsAt":1700001800000}
          },
          {
            "label":"Spark",
            "scope":{"tier":"spark","windowId":"5h"},
            "amount":{"usedFraction":0.34},
            "window":{"durationMs":18000000,"resetsAt":1700008220000}
          }
        ]
      },
      {
        "provider":"anthropic",
        "metadata":{"email":"claude.alpha@example.test"},
        "limits":[
          {
            "label":"Fable",
            "scope":{"tier":"fable"},
            "amount":{"usedFraction":0.8},
            "window":{"durationMs":604800000}
          },
          {
            "label":"7 day",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.51},
            "window":{"id":"7d","resetsAt":1700273600000}
          },
          {
            "label":"5 hour",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.45},
            "window":{"durationMs":18000000,"resetsAt":1700001800000}
          }
        ]
      }
    ]}
    EOF
    cat > "$fixtures/beta-usage.json" <<'EOF'
    {"reports":[
      {
        "provider":"anthropic",
        "metadata":{"email":"claude.beta@example.test"},
        "limits":[
          {
            "label":"7-day",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.05},
            "window":{"durationMs":604800000,"resetsAt":1700008220000}
          }
        ]
      },
      {
        "provider":"openai-codex",
        "metadata":{"email":"shared.codex@example.test"},
        "limits":[
          {
            "label":"5 hour",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.23},
            "window":{"durationMs":18000000,"resetsAt":1700001800000}
          },
          {
            "label":"7 day",
            "scope":{"tier":"-"},
            "amount":{"usedFraction":0.12},
            "window":{"durationMs":604800000}
          },
          {
            "label":"Spark 5 Hour",
            "scope":{"tier":"spark"},
            "amount":{"usedFraction":0.34},
            "window":{"durationMs":18000000,"resetsAt":1700008220000}
          },
          {
            "label":"Spark 7 Day",
            "scope":{"tier":"spark"},
            "amount":{"usedFraction":0.67},
            "window":{"durationMs":604800000,"resetsAt":1700273600000}
          }
        ]
      }
    ]}
    EOF

    cat > "$fixtures/bin/curl" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "''${CURL_ARGS_LOG:?}"
    cat >/dev/null # consume --config stdin without exposing the bearer
    if [ "''${CURL_FAIL:-0}" = 1 ]; then
      exit 22
    fi
    url=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --url ]; then
        url=$2
        break
      fi
      shift
    done
    case "$url" in
      http://127.0.0.1:41001/v1/snapshot) cat "''${FIXTURE_ROOT:?}/alpha-snapshot.json" ;;
      http://127.0.0.1:41001/v1/usage) cat "''${FIXTURE_ROOT:?}/alpha-usage.json" ;;
      http://127.0.0.1:41002/v1/snapshot) cat "''${FIXTURE_ROOT:?}/beta-snapshot.json" ;;
      http://127.0.0.1:41002/v1/usage) cat "''${FIXTURE_ROOT:?}/beta-usage.json" ;;
      *)
        printf 'unexpected URL: %s\n' "$url" >&2
        exit 64
        ;;
    esac
    EOF
    cat > "$fixtures/bin/herdr" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "''${HERDR_ARGS_LOG:?}"
    [ "''${HERDR_SOCKET_PATH:-}" = "''${EXPECTED_SOCKET:?}" ] || exit 65
    if [ "$#" -eq 3 ] &&
      [ "$1" = sidebar ] &&
      [ "$2" = report-section ] &&
      [ "$3" = --stdin ]; then
      cat > "''${HERDR_STDIN_CAPTURE:?}"
      exit 0
    fi
    exit 64
    EOF
    cat > "$fixtures/bin/date" <<'EOF'
    #!${pkgs.runtimeShell}
    [ "$#" -eq 1 ] && [ "$1" = '+%s%3N' ] || exit 64
    printf '1700000000000\n'
    EOF
    chmod +x "$fixtures/bin/curl" "$fixtures/bin/herdr" "$fixtures/bin/date"

    cat > "$fixtures/expected-rows.json" <<'EOF'
    [
      {
        "bar": {
          "fraction": 0.45,
          "title": "alpha 5h",
          "label": "45% ↻30m",
          "fill": "#e1c846",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.51,
          "title": "alpha 7d",
          "label": "51% ↻3d4h",
          "fill": "#ebc546",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.8,
          "title": "alpha fable",
          "label": "80%",
          "fill": "#eb6e46",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.05,
          "title": "beta 7d",
          "label": "5% ↻2h17m",
          "fill": "#69c846",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.23,
          "title": "shared.codex 5h",
          "label": "23% ↻30m",
          "fill": "#9fc846",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.12,
          "title": "shared.codex 7d",
          "label": "12%",
          "fill": "#7ec846",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.34,
          "title": "shared.codex sp 5h",
          "label": "34% ↻2h17m",
          "fill": "#c0c846",
          "empty": "#78829b"
        }
      },
      {
        "bar": {
          "fraction": 0.67,
          "title": "shared.codex sp 7d",
          "label": "67% ↻3d4h",
          "fill": "#eb9546",
          "empty": "#78829b"
        }
      }
    ]
    EOF

    run_publisher() {
      rm -f "$1"
      : > "$2"
      : > "$3"
      env PATH="$fixtures/bin:$PATH" \
        HERDR_USAGE_PUBLISHER_ONCE=1 \
        XDG_CONFIG_HOME="$fixtures/xdg" \
        CODE_AUTH_VAULTS_FILE="$fixtures/manifest.json" \
        CODE_AUTH_STATE="$fixtures/vault-state.json" \
        FIXTURE_ROOT="$fixtures" \
        CURL_ARGS_LOG="$2" \
        HERDR_ARGS_LOG="$3" \
        HERDR_STDIN_CAPTURE="$1" \
        EXPECTED_SOCKET="$fixtures/xdg/herdr/sessions/smoke/herdr.sock" \
        CURL_FAIL="$4" \
        bash ${../scripts/herdr-usage-publisher.sh}
    }

    capture="$fixtures/section.json"
    run_publisher "$capture" "$fixtures/curl.log" "$fixtures/herdr.log" 0
    jq -e '
      .section_id == "usage" and
      .source == "atyrode:usage" and
      .seq == 1700000000 and
      .ttl_ms == 720000 and
      (.rows | length) == 8
    ' "$capture" >/dev/null
    jq -e --slurpfile expected "$fixtures/expected-rows.json" \
      '.rows == $expected[0]' "$capture" >/dev/null
    jq -e '
      [.rows[].bar.title] == [
        "alpha 5h",
        "alpha 7d",
        "alpha fable",
        "beta 7d",
        "shared.codex 5h",
        "shared.codex 7d",
        "shared.codex sp 5h",
        "shared.codex sp 7d"
      ] and
      ([.rows[].bar.title | select(startswith("shared.codex "))] | length) == 4
    ' "$capture" >/dev/null
    jq -e '
      .rows[0].bar.fraction == 0.45 and
      .rows[0].bar.fill == "#e1c846" and
      .rows[0].bar.empty == "#78829b" and
      all(.rows[]; .bar.empty == "#78829b")
    ' "$capture" >/dev/null
    jq -e '
      [.rows[].bar.label] as $labels
      | any($labels[]; test("↻[0-9]+m$")) and
        any($labels[]; test("↻[0-9]+h[0-9]+m$")) and
        any($labels[]; test("↻[0-9]+d[0-9]+h$")) and
        all($labels[];
          test("^[0-9]+%( ↻([0-9]+m|[0-9]+h[0-9]+m|[0-9]+d[0-9]+h))?$")
        )
    ' "$capture" >/dev/null

    [ "$(cat "$fixtures/herdr.log")" = 'sidebar report-section --stdin' ]
    [ "$(grep -c -- '/v1/snapshot$' "$fixtures/curl.log")" -eq 2 ]
    [ "$(grep -c -- '/v1/usage$' "$fixtures/curl.log")" -eq 2 ]
    if grep -Fq 'sekret-bearer-' "$fixtures/curl.log" "$fixtures/herdr.log"; then
      echo 'bearer token leaked into stub argv' >&2
      exit 1
    fi
    if grep -Eq 'snapshot-secret-|alpha 5h|#e1c846|"rows"' \
      "$fixtures/curl.log" "$fixtures/herdr.log"; then
      echo 'section rows or snapshot credential material escaped stdin publication' >&2
      exit 1
    fi
    if grep -Fq 'snapshot-secret-' "$capture"; then
      echo 'snapshot credential material crossed the herdr socket' >&2
      exit 1
    fi

    # With every broker unavailable there are no rows and therefore no publish;
    # the prior owner expires naturally through the section TTL.
    run_publisher \
      "$fixtures/down-section.json" \
      "$fixtures/curl-down.log" \
      "$fixtures/herdr-down.log" \
      1 2>"$fixtures/down-stderr.log"
    test ! -e "$fixtures/down-section.json"
    test ! -s "$fixtures/herdr-down.log"
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
