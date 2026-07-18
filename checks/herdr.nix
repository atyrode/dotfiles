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
  && builtins.elem "default.target" usagePublisher.Install.WantedBy
) "the Linux herdr usage publisher must restart on failure and start with the user session";
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
    publisher=${lib.escapeShellArg usagePublisher.Service.ExecStart}
    bash -n "$publisher"

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
    taplo get -o json -f ${renderedConfig} 'ui.sidebar.spaces.rows' \
      | jq -e '. == [["state_icon", "workspace"], ["branch", "git_status"], ["$usage"]]' >/dev/null
    if taplo get -f ${renderedConfig} 'ui.sidebar.agents.rows_by_agent.omp' >/dev/null 2>&1; then
      echo "the OMP agent usage row must remain opt-in" >&2
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
