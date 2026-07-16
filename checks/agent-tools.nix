{
  lib,
  pkgs,
}:

let
  defaultsConfig = ../omp/defaults.yml;
  policyConfig = ../omp/policy.yml;
  untrustedConfig = ../omp/untrusted.yml;
  yoloConfig = ../omp/yolo-session.yml;
  settingsGuardExtension = ../omp/extensions/managed-settings-guard.ts;
  parallelWriteRule = ../omp/rules/parallel-write-isolation.md;
  plainSeedConfig = ../omp/plain-seed.yml;

  stubOmp =
    pkgs.runCommand "omp-stub"
      {
        meta = {
          mainProgram = "omp";
          platforms = lib.platforms.all;
        };
      }
      ''
            mkdir -p "$out/bin" "$out/share/zsh/site-functions"
            cat > "$out/bin/omp" <<'EOF'
        #!${pkgs.runtimeShell}
        printf '%s\n' "$@"
        EOF
            chmod +x "$out/bin/omp"
            printf '#compdef omp\n' > "$out/share/zsh/site-functions/_omp"
      '';

  configuredStub = pkgs.callPackage ../pkgs/omp-configured {
    omp = stubOmp;
  };
  untrustedStubOmp =
    pkgs.runCommand "omp-untrusted-stub"
      {
        meta = stubOmp.meta;
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
        printf 'OPENAI_API_KEY=%s\n' "''${OPENAI_API_KEY-unset}"
        printf 'GH_TOKEN=%s\n' "''${GH_TOKEN-unset}"
        printf 'SSH_AUTH_SOCK=%s\n' "''${SSH_AUTH_SOCK-unset}"
        printf '%s\n' '--args--' "$@"
        EOF
        chmod +x "$out/bin/omp"
        printf '#compdef omp\n' > "$out/share/zsh/site-functions/_omp"
      '';
  configuredUntrustedStub = pkgs.callPackage ../pkgs/omp-configured {
    omp = untrustedStubOmp;
  };
  evalAgentTools =
    platformPkgs:
    (lib.evalModules {
      specialArgs.pkgs = platformPkgs;
      modules = [
        (
          { lib, ... }:
          {
            options = {
              home.packages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
              home.file = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              home.activation = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              xdg.stateHome = lib.mkOption { type = lib.types.str; };
              xdg.configHome = lib.mkOption { type = lib.types.str; };
              xdg.cacheHome = lib.mkOption { type = lib.types.str; };
              xdg.configFile = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              services.ollama = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              systemd.user.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              launchd.agents = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
            };

            config = {
              xdg.configHome = "/tmp/check-agent-auth-vaults/xdg-config";
              xdg.stateHome = "/tmp/check-agent-auth-vaults/xdg-state";
              xdg.cacheHome = "/tmp/check-agent-auth-vaults/xdg-cache";
              atyrode.agentTools = {
                enable = true;
                migrateLegacy = false;
                seedPlainConfig = false;
                ompPackage = configuredStub;
                localClassifier.enable = false;
              };
            };
          }
        )
        ../modules/home/agent-tools.nix
      ];
    }).config;
  linuxAgentTools = evalAgentTools (
    pkgs
    // {
      stdenv = pkgs.stdenv // {
        isLinux = true;
        isDarwin = false;
      };
    }
  );
  darwinAgentTools = evalAgentTools (
    pkgs
    // {
      stdenv = pkgs.stdenv // {
        isLinux = false;
        isDarwin = true;
      };
    }
  );
  linuxBrokerSupervisor =
    linuxAgentTools.systemd.user.services.atyrode-omp-auth-brokers.Service.ExecStart;
  darwinBrokerAgent = darwinAgentTools.launchd.agents.atyrode-omp-auth-brokers;
in
{
  auth-vaults =
    pkgs.runCommand "check-agent-auth-vaults"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        supervisor=${lib.escapeShellArg linuxBrokerSupervisor}
        test ${lib.escapeShellArg (toString darwinBrokerAgent.enable)} = 1
        test ${lib.escapeShellArg (builtins.head darwinBrokerAgent.config.ProgramArguments)} = "$supervisor"
        grep -Fq 'code-auth-vaults.json' "$supervisor"
        grep -Fq 'chmod 0600 "$token_tmp"' "$supervisor"
        grep -Fq 'auth-broker serve --bind="$bind"' "$supervisor"

        rm -rf /tmp/check-agent-auth-vaults
        mkdir -p /tmp/check-agent-auth-vaults/xdg-config/atyrode
        cat > /tmp/check-agent-auth-vaults/xdg-config/atyrode/code-auth-vaults.json <<'JSON'
        [
          {
            "id": "primary",
            "label": "primary",
            "profile": "default",
            "claude": "Operator",
            "codex": "Operator",
            "brokerUrl": "http://127.0.0.1:47101",
            "tokenFile": "/tmp/check-agent-auth-vaults/state/primary/token",
            "snapshotCache": "/tmp/check-agent-auth-vaults/cache/primary.json"
          },
          {
            "id": "secondary",
            "label": "secondary",
            "profile": "team",
            "claude": "Collaborator",
            "codex": "Operator",
            "brokerUrl": "http://127.0.0.1:47102",
            "tokenFile": "/tmp/check-agent-auth-vaults/state/secondary/token",
            "snapshotCache": "/tmp/check-agent-auth-vaults/cache/secondary.json"
          }
        ]
        JSON
        chmod 0600 /tmp/check-agent-auth-vaults/xdg-config/atyrode/code-auth-vaults.json

        "$supervisor" > "$TMPDIR/broker-serve.out"

        primary=/tmp/check-agent-auth-vaults/state/primary/token
        secondary=/tmp/check-agent-auth-vaults/state/secondary/token
        test "$(stat -c %a "$primary")" = 600
        test "$(stat -c %a "$secondary")" = 600
        grep -Fxq default "$primary"
        grep -Fxq team "$secondary"
        grep -Fq 'auth-broker' "$primary"
        grep -Fq 'token' "$secondary"

        touch "$out"
      '';
  omp-stack =
    pkgs.runCommand "check-omp-stack"
      {
        nativeBuildInputs = [
          pkgs.bun
          pkgs.findutils
          pkgs.jq
          pkgs.yq-go
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        raw_omp=${lib.escapeShellArg (lib.getExe pkgs.omp)}
        raw_version="$("$raw_omp" --version)"
        test "''${raw_version##*/}" = "${lib.getVersion pkgs.omp}"

        for config in \
          ${defaultsConfig} \
          ${policyConfig} \
          ${untrustedConfig} \
          ${yoloConfig}
        do
          "$raw_omp" models --config "$config" --json >/dev/null
        done

        test "$(yq eval '.modelRoles.default' ${defaultsConfig})" = "openai-codex/gpt-5.6-sol:medium"
        test "$(yq eval '.modelRoles.task' ${defaultsConfig})" = "openai-codex/gpt-5.6-terra:medium"
        test "$(yq eval '.tools.approvalMode' ${defaultsConfig})" = "null"
        test "$(yq eval '.secrets.enabled' ${defaultsConfig})" = "null"
        test "$(yq eval '.tools.approvalMode' ${policyConfig})" = "yolo"
        test "$(yq eval '.secrets.enabled' ${policyConfig})" = "true"
        test "$(yq eval 'keys | sort | join(",")' ${policyConfig})" = "secrets,task,tools"
        test "$(yq eval '.tools | keys | sort | join(",")' ${policyConfig})" = "approval,approvalMode"
        for tool in bash eval browser task github; do
          test "$(yq eval ".tools.approval.$tool" ${policyConfig})" = "allow"
          test "$(yq eval ".tools.approval.$tool" ${yoloConfig})" = "allow"
        done
        test "$(yq eval '.secrets | keys | join(",")' ${policyConfig})" = "enabled"
        test "$(yq eval '.task.isolation.mode' ${policyConfig})" = "auto"
        test "$(yq eval '.task.isolation.merge' ${policyConfig})" = "patch"
        test "$(yq eval '.task.isolation.commits' ${policyConfig})" = "generic"
        test "$(yq eval '.tools.approvalMode' ${untrustedConfig})" = "always-ask"
        test "$(yq eval '.mcp.enableProjectConfig' ${untrustedConfig})" = "false"
        test "$(yq eval '.tools.approval.browser' ${untrustedConfig})" = "deny"
        test "$(yq eval '.tools.approval.github' ${untrustedConfig})" = "deny"
        test "$(yq eval '.tools.approval.eval' ${untrustedConfig})" = "deny"
        test "$(yq eval '.tools.approvalMode' ${yoloConfig})" = "null"

        # The hand-curated preset launchers were sunset: the managed bin set is
        # now exactly `code omp omp-managed ompu` (plus the zsh completion). The
        # omp-passthrough launchers report the pinned version; `code` is the
        # generator TUI and only answers --help non-interactively.
        for command in omp omp-managed ompu; do
          command_version="$(${pkgs.omp-configured}/bin/"$command" --version)"
          test "''${command_version##*/}" = "${lib.getVersion pkgs.omp}"
        done
        ${pkgs.omp-configured}/bin/code --help > "$TMPDIR/code-help.txt"
        grep -q 'build an OMP profile from a prompt' "$TMPDIR/code-help.txt"
        grep -q 'a cycles enabled' "$TMPDIR/code-help.txt"
        grep -q 'v opens the vault manager' "$TMPDIR/code-help.txt"
        ! grep -q 'pick an OMP launcher' "$TMPDIR/code-help.txt"
        # The generator owns mutable vault/selection state while broker
        # credentials stay outside the package and its generated manifest.
        grep -Fq 'export CODE_AUTH_STATE="''${CODE_AUTH_STATE:-''${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/code-auth-vault-state.json}"' \
          ${pkgs.omp-configured}/bin/code
        grep -Fq 'export CODE_SELECTION_STATE="''${CODE_SELECTION_STATE:-''${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/code-generator-selection.json}"' \
          ${pkgs.omp-configured}/bin/code
        grep -Fq 'export CODE_OMP_RAW="$omp_bin"' ${pkgs.omp-configured}/bin/code
        grep -Fq -- '--profile default usage --json' ${pkgs.omp-configured}/bin/code
        ! grep -Fq 'CODE_AUTH_VAULTS=' ${pkgs.omp-configured}/bin/code
        ! grep -Fq 'CODE_AUTH_PROFILES' ${pkgs.omp-configured}/bin/code
        ! grep -Fq 'code-auth-profiles.json' ${pkgs.omp-configured}/bin/code
        test ! -e ${pkgs.omp-configured}/bin/pi
        test "$(
          find ${pkgs.omp-configured}/bin -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd, -
        )" = "code,omp,omp-managed,ompu"
        # None of the retired preset launchers (or the routing-help/wiki surface)
        # survive.
        for gone in ompb ompc ompe ompf ompg omph ompk ompl ompm ompn ompo omps ompx ompz; do
          test ! -e ${pkgs.omp-configured}/bin/"$gone"
        done
        test ! -e ${pkgs.omp-configured}/share/omp/routes.html

        ${pkgs.omp-configured}/bin/omp models --json > "$TMPDIR/models.json" 2> "$TMPDIR/models.err"
        test ! -s "$TMPDIR/models.err"
        jq -e '.models | type == "array"' "$TMPDIR/models.json" >/dev/null

        set +e
        ${pkgs.omp-configured}/bin/omp-managed acp \
          --config "$TMPDIR/missing-one-shot.yml" \
          > "$TMPDIR/acp.out" 2> "$TMPDIR/acp.err"
        acp_status=$?
        set -e
        test "$acp_status" -ne 0
        grep -q 'Config overlay not found' "$TMPDIR/acp.err"

        acp_home="$TMPDIR/acp-home"
        mkdir -p "$acp_home"
        printf '%s\n' \
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' \
          | env HOME="$acp_home" PI_CODING_AGENT_DIR="$acp_home/agent" \
            timeout 20 ${pkgs.omp-configured}/bin/omp acp > "$TMPDIR/acp-init.jsonl"
        jq -e \
          '.id == 1 and .result.protocolVersion == 1 and .result.agentInfo.version == $version' \
          --arg version "${lib.getVersion pkgs.omp}" \
          "$TMPDIR/acp-init.jsonl" >/dev/null
        test ! -e "$acp_home/.pi"

        rpc_home="$TMPDIR/rpc-home"
        rpc_project="$TMPDIR/rpc-project"
        mkdir -p "$rpc_home" "$rpc_project/.omp" "$rpc_project/.agents/skills/project-fixture"
        printf '%s\n' 'managed-project-guidance-fixture' > "$rpc_project/.omp/AGENTS.md"
        printf '%s\n' '{"defaultThinkingLevel":"low"}' > "$rpc_project/.omp/settings.json"
        cat > "$rpc_project/.omp/config.yml" <<'EOF'
        defaultThinkingLevel: high
        tools:
          approvalMode: yolo
        secrets:
          enabled: false
        EOF
        cat > "$rpc_project/.agents/skills/project-fixture/SKILL.md" <<'EOF'
        ---
        name: project-fixture
        description: managed-project-skill-fixture
        ---

        Project fixture skill.
        EOF
        printf '%s\n' \
          '{"id":"state","type":"get_state"}' \
          '{"id":"commands","type":"get_available_commands"}' \
          | env \
            HOME="$rpc_home" \
            OPENAI_API_KEY=fixture-placeholder \
            timeout 20 ${pkgs.omp-configured}/bin/omp \
              --profile work \
              --cwd "$rpc_project" \
              --mode rpc \
              --no-session \
              --no-tools \
              --no-lsp > "$TMPDIR/rpc.jsonl"
        jq -s -e '
          (map(select(.id == "state" and .success == true))[0].data
            | (.thinkingLevel == "high")
              and (.systemPrompt | join("\n") | contains("managed-project-guidance-fixture")))
          and
          (map(select(.id == "commands" and .success == true))[0].data.commands
            | any(.name == "skill:project-fixture" and .description == "managed-project-skill-fixture"))
        ' "$TMPDIR/rpc.jsonl" >/dev/null
        test ! -e "$rpc_home/.pi"

        cat > "$TMPDIR/settings-guard.test.ts" <<'EOF'
        import guard, {
          restoreManagedPaths,
          resolveMachineConfigPath,
        } from "${settingsGuardExtension}";

        const restored = restoreManagedPaths(
          {
            modelRoles: { default: "changed", extra: "keep" },
            custom: { keep: true },
          },
          { modelRoles: { default: "baseline" } },
        );
        if (!restored.changed) throw new Error("managed change was not detected");
        const config = restored.config as Record<string, any>;
        if (config.modelRoles.default !== "baseline") throw new Error("managed value was not restored");
        if (config.modelRoles.extra !== undefined) throw new Error("managed parent was only partially restored");
        if (config.custom.keep !== true) throw new Error("unmanaged value was lost");

        const agentDir = `''${process.env.HOME}/.omp/agent`;
        await Bun.write(`''${agentDir}/config.yaml`, "custom: baseline\n");
        if (!resolveMachineConfigPath().endsWith("config.yaml")) {
          throw new Error("legacy yaml fallback was not selected");
        }

        const handlers = new Map<string, Function>();
        const pi = { on(name: string, handler: Function) { handlers.set(name, handler); } };
        guard(pi as any);
        let warning = "";
        await handlers.get("session_start")?.({}, {
          ui: { notify(message: string) { warning = message; } },
        });
        await Bun.write(
          `''${agentDir}/config.yaml`,
          "modelRoles:\n  default: attempted-change\ncustom: preserved-edit\n",
        );
        await Bun.sleep(1_200);
        const watched = Bun.YAML.parse(await Bun.file(`''${agentDir}/config.yaml`).text());
        if (watched.modelRoles !== undefined || watched.custom !== "preserved-edit") {
          throw new Error("watcher did not restore managed paths and retain unmanaged edits");
        }
        if (!warning.includes("tried to change Nix-managed")) {
          throw new Error("watcher did not report the rejected persistence");
        }
        warning = "";
        const settingsResult = await handlers.get("input")?.(
          { text: "  /SeTtInGs  " },
          { ui: { notify(message: string) { warning = message; } } },
        );
        if (settingsResult?.handled !== true || !warning.includes("Nix-managed settings")) {
          throw new Error("settings command was not guarded");
        }
        if (await handlers.get("input")?.({ text: "/settingsx" }, { ui: { notify() {} } })) {
          throw new Error("unrelated input was consumed");
        }
        await handlers.get("session_shutdown")?.();
        EOF
        mkdir -p "$HOME/.omp/agent"
        ${pkgs.bun}/bin/bun "$TMPDIR/settings-guard.test.ts"

        # #78 — managed launchers are immutable at LAUNCH: a hostile ~/.omp cannot
        # override the managed routing default or enforced policy (approvals,
        # task isolation), and `config set` on a managed path is refused. The
        # in-session guard above covers the running-session half; this covers the
        # next-launch half that makes profiles reliable.
        imm_home="$TMPDIR/immutable-home"
        mkdir -p "$imm_home/.omp/agent"
        cat > "$imm_home/.omp/agent/config.yml" <<'YAML'
        modelRoles:
          default: openai-codex/gpt-5.6-luna:minimal
        tools:
          approvalMode: always-ask
        task:
          isolation:
            mode: none
        YAML
        env HOME="$imm_home" ${pkgs.omp-configured}/bin/omp-managed config managed --json \
          > "$TMPDIR/effective.json"
        # routing: the managed default wins over the user's weak pin
        test "$(jq -r '.effectiveManaged.modelRoles.default' "$TMPDIR/effective.json")" \
          = "openai-codex/gpt-5.6-sol:medium"
        # enforced policy: the user cannot weaken approvals or task isolation
        test "$(jq -r '.effectiveManaged.tools.approvalMode' "$TMPDIR/effective.json")" = "yolo"
        test "$(jq -r '.effectiveManaged.task.isolation.mode' "$TMPDIR/effective.json")" = "auto"
        # the user's own bare-omp machine config is left untouched (still theirs)
        test "$(yq eval '.modelRoles.default' "$imm_home/.omp/agent/config.yml")" \
          = "openai-codex/gpt-5.6-luna:minimal"
        # and the CLI refuses to set a managed path from a managed launcher
        set +e
        env HOME="$imm_home" ${pkgs.omp-configured}/bin/omp-managed config set \
          modelRoles.default openai-codex/gpt-5.6-luna:low \
          > "$TMPDIR/cfgset.out" 2> "$TMPDIR/cfgset.err"
        cfgset_status=$?
        set -e
        test "$cfgset_status" -ne 0
        grep -q 'Nix-managed' "$TMPDIR/cfgset.err"

        # The task-isolation mandate is retired (#175): isolation is upstream's
        # per-spawn opt-in, so no guard extension may ship — only the guidance
        # rule. A reintroduced guard must be a deliberate decision, not drift.
        test ! -e ${pkgs.omp-configured.platformRoot}/extensions/task-isolation-guard.ts
        grep -q 'isolated: true' ${parallelWriteRule}

        test "$(
          find ${pkgs.omp-agents}/share/omp/agents -maxdepth 1 -name '*.md' | wc -l
        )" -eq 6
        test "$(find ${pkgs.omp-configured.platformRoot}/agents -maxdepth 1 -name '*.md' | wc -l)" -eq 6
        test -f ${pkgs.omp-configured.platformRoot}/extensions/managed-settings-guard.ts
        test -f ${pkgs.omp-configured.platformRoot}/rules/no-shell-text-surgery.md
        test -f ${pkgs.omp-configured.platformRoot}/rules/parallel-write-isolation.md

        mkdir "$out"
      '';

  # Upstream agent renames and removals must fail the build instead of
  # silently misrouting models (#62): every agent name referenced by the
  # managed configs has to exist in the pinned unpacked set.
  omp-agent-references =
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
      '';

  omp-wrapper =
    pkgs.runCommand "check-omp-wrapper"
      {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.jq
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
            grep -q 'Nix-owned settings guard' "$TMPDIR/no-extensions.err"

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
            grep -q 'matches sessions in multiple OMP state roots' "$TMPDIR/ambiguous.err"


            set +e
            ${configuredStub}/bin/omp update \
              > "$TMPDIR/plain-update.out" 2> "$TMPDIR/plain-update.err"
            plain_update_status=$?
            set -e
            test "$plain_update_status" -eq 2
            grep -q 'managed by Nix' "$TMPDIR/plain-update.err"

            ${configuredStub}/bin/omp --help config > "$TMPDIR/actual"
            printf '%s\n' '--help' 'config' > "$TMPDIR/expected"
            diff -u "$TMPDIR/expected" "$TMPDIR/actual"

            ${configuredStub}/bin/omp-managed config set completion.notify off --json > "$TMPDIR/actual"
            printf '%s\n' 'config' 'set' 'completion.notify' 'off' '--json' > "$TMPDIR/expected"
            diff -u "$TMPDIR/expected" "$TMPDIR/actual"

            for invocation in \
              'config set modelRoles {}' \
              'config set tools {}' \
              'config --json reset providers.webSearch' \
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
              grep -Eq 'Nix-managed default|Nix-managed preset|enforced by Nix policy' "$TMPDIR/refused.err"
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
              "mode":"auto","merge":"patch","commits":"generic"
            }' "$TMPDIR/managed.json" >/dev/null
            jq -e '.effectiveManaged.privateToken == null' "$TMPDIR/managed.json" >/dev/null
            ! grep -q 'do-not-print' "$TMPDIR/managed.json"
            jq -e '.enforcedPolicy == {
              "tools":{"approvalMode":"yolo","approval":{
                "bash":"allow","eval":"allow","browser":"allow","task":"allow","github":"allow"
              }},
              "secrets":{"enabled":true},
              "task":{"isolation":{"mode":"auto","merge":"patch","commits":"generic"}}
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
            grep -q 'unattended yolo mode is enabled for this process only' "$TMPDIR/yolo.err"
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
            grep -q 'Invalid OMP profile' "$TMPDIR/invalid-profile.err"

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

            legacy_project="$TMPDIR/legacy-project"
            mkdir -p "$legacy_project/.omp"
            cat > "$legacy_project/.omp/config.yml" <<'EOF'
        theme: custom-dark
        codexResets:
          autoRedeem: true
        memories:
          enabled: false
        EOF
            cat > "$legacy_project/relative.yml" <<'EOF'
        modelRoles:
          default: relative/one-shot:high
        EOF
            ${configuredStub}/bin/omp-managed \
              --cwd "$legacy_project" \
              --config relative.yml \
              config managed --json > "$TMPDIR/legacy-managed.json"
            jq -e --arg oneShot "$legacy_project/relative.yml" '
              .effectiveManaged.theme.dark == "custom-dark"
              and .effectiveManaged.codexResets.autoRedeem == "yes"
              and .effectiveManaged.memory.backend == "off"
              and .effectiveManaged.modelRoles.default == "relative/one-shot:high"
              and (.sources[] | select(.kind == "one-shot-config") | .path == $oneShot)
            ' "$TMPDIR/legacy-managed.json" >/dev/null

            set +e
            ${configuredStub}/bin/omp-managed config get modelRoles --json \
              > "$TMPDIR/get.out" 2> "$TMPDIR/get.err"
            get_status=$?
            set -e
            test "$get_status" -eq 2
            grep -q 'only reads writable machine state' "$TMPDIR/get.err"

            ${configuredStub}/bin/omp-managed config list > "$TMPDIR/list.out" 2> "$TMPDIR/list.err"
            grep -q 'shows writable machine state' "$TMPDIR/list.err"

            ${configuredStub}/bin/omp-managed setup --help > "$TMPDIR/setup.out" 2> "$TMPDIR/setup.err"
            printf '%s\n' setup --help > "$TMPDIR/expected"
            diff -u "$TMPDIR/expected" "$TMPDIR/setup.out"
            grep -q 'writes writable machine state' "$TMPDIR/setup.err"

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
              grep -q 'managed by Nix' "$TMPDIR/update.err"
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
              ${configuredUntrustedStub}/bin/ompu \
                --cwd "$untrusted_project" --mode rpc --no-session \
                > "$TMPDIR/untrusted.out"
            grep -Fx "cwd=${configuredUntrustedStub.neutralRoot}" "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx "HOME=$untrusted_home/.local/state/atyrode/omp-untrusted/home" \
              "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'OMP_PROFILE=untrusted' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'PI_PROFILE=untrusted' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'PI_JS=0' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'PI_PY=0' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'OPENAI_API_KEY=unset' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'GH_TOKEN=unset' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx 'SSH_AUTH_SOCK=unset' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx '${configuredUntrustedStub.untrustedConfig}' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx "$untrusted_project/.omp/settings.json" "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx "$untrusted_project/.omp/config.yml" "$TMPDIR/untrusted.out" >/dev/null
            test "$(grep -nFx '${configuredUntrustedStub.untrustedConfig}' "$TMPDIR/untrusted.out" | cut -d: -f1)" \
              -gt "$(grep -nFx "$untrusted_project/.omp/config.yml" "$TMPDIR/untrusted.out" | cut -d: -f1)"
            grep -Fx -- '--no-lsp' "$TMPDIR/untrusted.out" >/dev/null
            grep -Fx -- '--no-pty' "$TMPDIR/untrusted.out" >/dev/null

            for unsafe in '--yolo' '--approval-mode yolo' '--config attacker.yml' '--no-extensions'; do
              read -r -a args <<< "$unsafe"
              set +e
              HOME="$untrusted_home" ${configuredUntrustedStub}/bin/ompu "''${args[@]}" \
                > "$TMPDIR/untrusted-refused.out" 2> "$TMPDIR/untrusted-refused.err"
              untrusted_refused_status=$?
              set -e
              test "$untrusted_refused_status" -eq 2
              grep -q "ompu refused" "$TMPDIR/untrusted-refused.err"
            done

            mkdir -p "$untrusted_project/.omp/extensions"
            set +e
            HOME="$untrusted_home" ${configuredUntrustedStub}/bin/ompu --cwd "$untrusted_project" \
              > "$TMPDIR/untrusted-project.out" 2> "$TMPDIR/untrusted-project.err"
            executable_project_status=$?
            set -e
            test "$executable_project_status" -eq 2
            grep -q 'executable or policy-bearing project state' "$TMPDIR/untrusted-project.err"

            mkdir "$out"
      '';

  agent-tools-migration =
    pkgs.runCommand "check-agent-tools-migration"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.flock
          pkgs.gnugrep
          pkgs.jq
          pkgs.yq-go
        ];
      }
      ''
            migration=${lib.escapeShellArg (lib.getExe pkgs.agent-tools-migrate)}

            empty_home_files="$TMPDIR/empty-home-files"
            mkdir -p "$empty_home_files"

            export HOME="$TMPDIR/home"
            mkdir -p \
              "$HOME/.local/bin" \
              "$HOME/.omp/plugins/node_modules/bigpowers" \
              "$HOME/.omp/agent/agents" \
              "$HOME/.omp/agent/extensions" \
              "$HOME/.omp/agent/rules" \
              "$HOME/.omp/agent/managed-skills/ts-react-dead-code-sweep"

            printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/omp"
            printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/herdr"
            chmod +x "$HOME/.local/bin/omp" "$HOME/.local/bin/herdr"
            printf '{"dependencies":{"bigpowers":"2.76.2"}}\n' > "$HOME/.omp/plugins/package.json"
            printf 'legacy\n' > "$HOME/.omp/agent/agents/task.md"
            printf 'legacy\n' > "$HOME/.omp/agent/extensions/herdr-omp-agent-state.ts"
            printf 'legacy\n' > "$HOME/.omp/agent/extensions/managed-settings-guard.ts"
            printf 'legacy\n' > "$HOME/.omp/agent/rules/no-shell-text-surgery.md"
            printf 'legacy\n' > "$HOME/.omp/agent/gpt56-only.yml"
            printf 'legacy\n' > "$HOME/.omp/agent/managed-skills/ts-react-dead-code-sweep/SKILL.md"
            cat > "$HOME/.omp/agent/mcp.json" <<'EOF'
        {
          "$schema": "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json",
          "mcpServers": {},
          "disabledServers": ["bigpowers-mcp"]
        }
        EOF
            cat > "$HOME/.omp/agent/config.yml" <<'EOF'
        setupVersion: 7
        "codexResets.autoRedeem": true
        dev:
          autoqa:
            consent: accepted
        modelRoles:
          default: legacy/model
        providers:
          anthropic:
            serverSideFallback: true
        retry:
          enabled: true
          custom: preserved
        tools:
          approvalMode: yolo
          approval:
            bash: allow
            eval: allow
            browser: allow
            task: allow
            github: allow
          custom: preserved
        secrets:
          enabled: false
          custom: preserved
        custom:
          nested: preserved
        advisor:
          enabled: true
          immuneTurns: 7
        statusLine:
          preset: default
          separator: preserved
        terminal:
          showProgress: true
          showImages: false
        tui:
          tight: false
          renderMermaid: true
        display:
          shimmer: classic
          smoothStreaming: false
        codexResets:
          autoRedeem: "no"
          minBlockedMinutes: 42
        task:
          disabledAgents: []
          isolation:
            mode: none
            merge: commits
            commits: agent
          maxConcurrency: 3
        memory:
          backend: local
          custom: preserved
        theme:
          dark: dark
          light: light
        browser:
          enabled: true
          custom: preserved
        EOF

            "$migration" prepare
            state_root="$HOME/.local/state/atyrode/agent-tools-migration"
            pending="$state_root/migration-v2.pending"
            complete="$state_root/migration-v2.complete"
            test -d "$pending"
            test ! -e "$complete"
            test -x "$pending/backup/.local/bin/omp"
            test -f "$pending/backup/.omp/agent/config.yml"
            test ! -e "$HOME/.omp/agent/mcp.json"
            test "$(yq eval '.setupVersion' "$HOME/.omp/agent/config.yml")" = "7"
            test "$(yq eval '.custom.nested' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.modelRoles' "$HOME/.omp/agent/config.yml")" = "null"
            # serverSideFallback is no longer Nix-managed (the fable preset that owned
            # it is gone), so migration must PRESERVE the user's value, not strip it.
            test "$(yq eval '.providers.anthropic.serverSideFallback' "$HOME/.omp/agent/config.yml")" = "true"
            test "$(yq eval '."codexResets.autoRedeem"' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.retry.enabled' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.retry.custom' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.tools.custom' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.tools.approval' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.secrets.custom' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.advisor.immuneTurns' "$HOME/.omp/agent/config.yml")" = "7"
            test "$(yq eval '.statusLine.separator' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.terminal.showImages' "$HOME/.omp/agent/config.yml")" = "false"
            test "$(yq eval '.tui.renderMermaid' "$HOME/.omp/agent/config.yml")" = "true"
            test "$(yq eval '.display.smoothStreaming' "$HOME/.omp/agent/config.yml")" = "false"
            test "$(yq eval '.codexResets.minBlockedMinutes' "$HOME/.omp/agent/config.yml")" = "42"
            test "$(yq eval '.task.maxConcurrency' "$HOME/.omp/agent/config.yml")" = "3"
            test "$(yq eval '.task.isolation' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.memory.custom' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.theme.light' "$HOME/.omp/agent/config.yml")" = "light"
            test "$(yq eval '.browser.custom' "$HOME/.omp/agent/config.yml")" = "preserved"

            "$migration" finalize "$empty_home_files"
            test -d "$complete"
            test ! -e "$pending"
            test -x "$complete/backup/.local/bin/omp"
            test -f "$complete/backup/.omp/plugins/package.json"
            test -f "$complete/backup/.omp/agent/agents/task.md"
            test -f "$complete/backup/.omp/agent/extensions/managed-settings-guard.ts"
            test -f "$complete/backup/.omp/agent/mcp.json"
            test ! -e "$HOME/.omp/agent/agents/task.md"
            test ! -e "$HOME/.omp/agent/extensions/managed-settings-guard.ts"

            "$migration" prepare
            "$migration" finalize "$empty_home_files"
            test "$(find "$state_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1

            reboot_home="$TMPDIR/reboot-home"
            HOME="$reboot_home" "$migration" prepare
            reboot_complete="$reboot_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"
            HOME="$reboot_home" "$migration" finalize "$empty_home_files"
            : > "$reboot_complete/receipt.tsv"
            HOME="$reboot_home" "$migration" prepare
            HOME="$reboot_home" "$migration" finalize "$empty_home_files"
            test -d "$reboot_complete"
            test -z "$(find "$reboot_complete/backup" "$reboot_complete/work" -mindepth 1 -print -quit)"

            retained_empty_home="$TMPDIR/retained-empty-home"
            retained_empty_complete="$retained_empty_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"
            mkdir -p "$retained_empty_complete/backup/.local/bin" "$retained_empty_complete/work"
            : > "$retained_empty_complete/receipt.tsv"
            printf 'unrecorded operator data\n' > "$retained_empty_complete/backup/.local/bin/omp"
            if HOME="$retained_empty_home" "$migration" prepare \
              > "$TMPDIR/retained-empty.out" 2> "$TMPDIR/retained-empty.err"; then
              exit 1
            fi
            grep -q 'empty receipt with retained migration data' "$TMPDIR/retained-empty.err"

            symlinked_complete_home="$TMPDIR/symlinked-complete-home"
            mkdir -p "$symlinked_complete_home/state-target/backup" \
              "$symlinked_complete_home/state-target/work" \
              "$symlinked_complete_home/.local/state/atyrode/agent-tools-migration"
            : > "$symlinked_complete_home/state-target/receipt.tsv"
            ln -s "$symlinked_complete_home/state-target" \
              "$symlinked_complete_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"
            if HOME="$symlinked_complete_home" "$migration" prepare \
              > "$TMPDIR/symlinked-complete.out" 2> "$TMPDIR/symlinked-complete.err"; then
              exit 1
            fi
            grep -q 'not a migration receipt directory' "$TMPDIR/symlinked-complete.err"

            dry_home="$TMPDIR/dry-home"
            mkdir -p "$dry_home/.local/bin"
            cp "$complete/backup/.local/bin/omp" "$dry_home/.local/bin/omp"
            HOME="$dry_home" AGENT_TOOLS_DRY_RUN=1 "$migration" prepare >/dev/null
            test -x "$dry_home/.local/bin/omp"
            test ! -e "$dry_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"

            interrupted_home="$TMPDIR/interrupted-home"
            mkdir -p "$interrupted_home/.local/bin"
            printf 'old omp\n' > "$interrupted_home/.local/bin/omp"
            printf 'old herdr\n' > "$interrupted_home/.local/bin/herdr"
            if HOME="$interrupted_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-first-move \
              "$migration" prepare > "$TMPDIR/interrupted.out" 2> "$TMPDIR/interrupted.err"; then
              exit 1
            fi
            interrupted_pending="$interrupted_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            test -d "$interrupted_pending"
            test -f "$interrupted_pending/backup/.local/bin/omp"
            test -f "$interrupted_home/.local/bin/herdr"
            HOME="$interrupted_home" "$migration" prepare
            test -f "$interrupted_pending/backup/.local/bin/herdr"
            HOME="$interrupted_home" "$migration" finalize "$empty_home_files"
            test -d "$interrupted_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"

            receipt_home="$TMPDIR/receipt-home"
            mkdir -p "$receipt_home/.local/bin"
            printf 'old omp\n' > "$receipt_home/.local/bin/omp"
            if HOME="$receipt_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-receipt \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            receipt_pending="$receipt_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            test -d "$receipt_pending"
            test -f "$receipt_home/.local/bin/omp"
            HOME="$receipt_home" "$migration" prepare
            HOME="$receipt_home" "$migration" finalize "$empty_home_files"
            test -d "$receipt_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"

            config_interrupt_home="$TMPDIR/config-interrupt-home"
            mkdir -p "$config_interrupt_home/.omp/agent"
            cat > "$config_interrupt_home/.omp/agent/config.yml" <<'EOF'
        modelRoles:
          default: legacy/model
        custom:
          preserved: true
        EOF
            if HOME="$config_interrupt_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-config-replace \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            test -d "$config_interrupt_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            test "$(yq eval '.modelRoles' "$config_interrupt_home/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.custom.preserved' "$config_interrupt_home/.omp/agent/config.yml")" = "true"
            HOME="$config_interrupt_home" "$migration" prepare
            HOME="$config_interrupt_home" "$migration" finalize "$empty_home_files"
            test -d "$config_interrupt_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"

            yaml_migration_home="$TMPDIR/yaml-migration-home"
            mkdir -p "$yaml_migration_home/.omp/agent"
            cat > "$yaml_migration_home/.omp/agent/config.yaml" <<'EOF'
        theme: dark
        modelRoles:
          default: legacy/model
        custom:
          preserved: true
        EOF
            HOME="$yaml_migration_home" "$migration" prepare
            yaml_pending="$yaml_migration_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            test -f "$yaml_pending/backup/.omp/agent/config.yaml"
            test ! -e "$yaml_migration_home/.omp/agent/config.yml"
            test "$(yq eval '.theme' "$yaml_migration_home/.omp/agent/config.yaml")" = "null"
            test "$(yq eval '.modelRoles' "$yaml_migration_home/.omp/agent/config.yaml")" = "null"
            test "$(yq eval '.custom.preserved' "$yaml_migration_home/.omp/agent/config.yaml")" = "true"
            HOME="$yaml_migration_home" "$migration" finalize "$empty_home_files"

            dual_config_home="$TMPDIR/dual-config-home"
            mkdir -p "$dual_config_home/.omp/agent"
            printf 'custom: yml\n' > "$dual_config_home/.omp/agent/config.yml"
            printf 'custom: yaml\n' > "$dual_config_home/.omp/agent/config.yaml"
            if HOME="$dual_config_home" "$migration" prepare \
              > "$TMPDIR/dual-config.out" 2> "$TMPDIR/dual-config.err"; then
              exit 1
            fi
            grep -q 'both .*config.yml and .*config.yaml exist' "$TMPDIR/dual-config.err"
            test -f "$dual_config_home/.omp/agent/config.yml"
            test -f "$dual_config_home/.omp/agent/config.yaml"

            scalar_theme_home="$TMPDIR/scalar-theme-home"
            mkdir -p "$scalar_theme_home/.omp/agent"
            printf 'theme: custom-light\n' > "$scalar_theme_home/.omp/agent/config.yml"
            if HOME="$scalar_theme_home" "$migration" prepare \
              > "$TMPDIR/scalar-theme.out" 2> "$TMPDIR/scalar-theme.err"; then
              exit 1
            fi
            grep -q 'legacy scalar custom theme' "$TMPDIR/scalar-theme.err"
            grep -q '^theme: custom-light$' "$scalar_theme_home/.omp/agent/config.yml"

            transformed_tamper_home="$TMPDIR/transformed-tamper-home"
            mkdir -p "$transformed_tamper_home/.omp/agent"
            printf 'modelRoles: {default: legacy/model}\ncustom: preserved\n' \
              > "$transformed_tamper_home/.omp/agent/config.yml"
            if HOME="$transformed_tamper_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-config-transform \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            transformed_pending="$transformed_tamper_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            printf 'custom: tampered\n' > "$transformed_pending/work/config.transformed.yml"
            if HOME="$transformed_tamper_home" "$migration" prepare \
              > "$TMPDIR/transformed-tamper.out" 2> "$TMPDIR/transformed-tamper.err"; then
              exit 1
            fi
            grep -q 'does not match the digest-verified original config' \
              "$TMPDIR/transformed-tamper.err"
            test "$(yq eval '.modelRoles.default' "$transformed_tamper_home/.omp/agent/config.yml")" = \
              'legacy/model'

            finalize_interrupt_home="$TMPDIR/finalize-interrupt-home"
            mkdir -p "$finalize_interrupt_home/.local/bin"
            printf 'old omp\n' > "$finalize_interrupt_home/.local/bin/omp"
            HOME="$finalize_interrupt_home" "$migration" prepare
            if HOME="$finalize_interrupt_home" AGENT_TOOLS_MIGRATION_FAILPOINT=before-finalize \
              "$migration" finalize "$empty_home_files" >/dev/null 2>&1; then
              exit 1
            fi
            test -d "$finalize_interrupt_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            HOME="$finalize_interrupt_home" "$migration" finalize "$empty_home_files"
            test -d "$finalize_interrupt_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"

            collision_home="$TMPDIR/collision-home"
            mkdir -p "$collision_home/.local/bin"
            printf 'original\n' > "$collision_home/.local/bin/omp"
            if HOME="$collision_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-first-move \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            printf 'replacement\n' > "$collision_home/.local/bin/omp"
            if HOME="$collision_home" "$migration" prepare > "$TMPDIR/collision.out" 2> "$TMPDIR/collision.err"; then
              exit 1
            fi
            grep -q 'preserve both and resolve the collision' "$TMPDIR/collision.err"
            grep -q '^replacement$' "$collision_home/.local/bin/omp"
            grep -q '^original$' \
              "$collision_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending/backup/.local/bin/omp"

            opaque_home="$TMPDIR/opaque-home"
            mkdir -p "$opaque_home/.local/bin"
            cat > "$opaque_home/.local/bin/omp" <<'EOF'
        #!/bin/sh
        touch "$HOME/executed"
        EOF
            chmod +x "$opaque_home/.local/bin/omp"
            HOME="$opaque_home" "$migration" prepare
            test ! -e "$opaque_home/executed"
            HOME="$opaque_home" "$migration" finalize "$empty_home_files"
            test -x "$opaque_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete/backup/.local/bin/omp"

            custom_mcp_home="$TMPDIR/custom-mcp-home"
            mkdir -p "$custom_mcp_home/.omp/agent"
            cat > "$custom_mcp_home/.omp/agent/mcp.json" <<'EOF'
        {"mcpServers":{"custom":{"command":"custom-mcp"}},"disabledServers":["bigpowers-mcp"]}
        EOF
            HOME="$custom_mcp_home" "$migration" prepare
            HOME="$custom_mcp_home" "$migration" finalize "$empty_home_files"
            jq -e '.mcpServers.custom.command == "custom-mcp"' \
              "$custom_mcp_home/.omp/agent/mcp.json" >/dev/null

            mixed_plugin_home="$TMPDIR/mixed-plugin-home"
            mkdir -p \
              "$mixed_plugin_home/.omp/plugins/node_modules/bigpowers" \
              "$mixed_plugin_home/.omp/plugins/node_modules/custom-plugin"
            printf '%s\n' \
              '{"dependencies":{"bigpowers":"2.76.2","custom-plugin":"1.0.0"}}' \
              > "$mixed_plugin_home/.omp/plugins/package.json"
            if HOME="$mixed_plugin_home" "$migration" prepare \
              > "$TMPDIR/mixed-plugin.out" 2> "$TMPDIR/mixed-plugin.err"; then
              exit 1
            fi
            grep -q 'mixed or customized plugin state' "$TMPDIR/mixed-plugin.err"
            test -d "$mixed_plugin_home/.omp/plugins/node_modules/bigpowers"
            test -d "$mixed_plugin_home/.omp/plugins/node_modules/custom-plugin"
            test ! -e "$mixed_plugin_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"

            stale_store_home="$TMPDIR/stale-store-home"
            mkdir -p "$stale_store_home/.local/bin"
            ln -s ${lib.getExe pkgs.hello} "$stale_store_home/.local/bin/omp"
            HOME="$stale_store_home" "$migration" prepare
            test ! -e "$stale_store_home/.local/bin/omp"
            test -L \
              "$stale_store_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending/backup/.local/bin/omp"
            HOME="$stale_store_home" "$migration" finalize "$empty_home_files"

            temp_link_home="$TMPDIR/temp-link-home"
            mkdir -p "$temp_link_home/.omp/agent"
            printf 'victim\n' > "$temp_link_home/victim"
            printf 'modelRoles: {default: legacy/model}\n' > "$temp_link_home/.omp/agent/config.yml"
            ln -s "$temp_link_home/victim" \
              "$temp_link_home/.omp/agent/config.yml.agent-tools-migration-v2.tmp"
            HOME="$temp_link_home" "$migration" prepare
            grep -q '^victim$' "$temp_link_home/victim"
            test -f "$temp_link_home/.omp/agent/config.yml"
            test ! -L "$temp_link_home/.omp/agent/config.yml"
            HOME="$temp_link_home" "$migration" finalize "$empty_home_files"

            receipt_escape_home="$TMPDIR/receipt-escape-home"
            mkdir -p "$receipt_escape_home/.local/bin" "$receipt_escape_home/escape"
            printf 'old omp\n' > "$receipt_escape_home/.local/bin/omp"
            if HOME="$receipt_escape_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-receipt \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            escape_pending="$receipt_escape_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            rm -rf "$escape_pending/backup"
            ln -s "$receipt_escape_home/escape" "$escape_pending/backup"
            if HOME="$receipt_escape_home" "$migration" prepare \
              > "$TMPDIR/receipt-escape.out" 2> "$TMPDIR/receipt-escape.err"; then
              exit 1
            fi
            grep -q 'not a safe receipt directory' "$TMPDIR/receipt-escape.err"
            test -f "$receipt_escape_home/.local/bin/omp"
            test -z "$(find "$receipt_escape_home/escape" -mindepth 1 -print -quit)"

            unsafe_home="$TMPDIR/unsafe-home"
            mkdir -p "$unsafe_home/.local/bin/omp"
            if HOME="$unsafe_home" "$migration" prepare > "$TMPDIR/unsafe.out" 2> "$TMPDIR/unsafe.err"; then
              exit 1
            fi
            grep -q 'not a regular file or symlink' "$TMPDIR/unsafe.err"
            test -d "$unsafe_home/.local/bin/omp"
            test ! -e "$unsafe_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"

            invalid_home="$TMPDIR/invalid-home"
            mkdir -p "$invalid_home/.local/bin" "$invalid_home/.omp/agent"
            printf 'legacy\n' > "$invalid_home/.local/bin/omp"
            printf '[invalid\n' > "$invalid_home/.omp/agent/config.yml"
            if HOME="$invalid_home" "$migration" prepare > "$TMPDIR/invalid.out" 2> "$TMPDIR/invalid.err"; then
              exit 1
            fi
            grep -q 'not valid YAML' "$TMPDIR/invalid.err"
            test -f "$invalid_home/.local/bin/omp"
            test ! -e "$invalid_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            test -z "$(
              find "$invalid_home/.local/state/atyrode/agent-tools-migration" \
                -maxdepth 1 -name '.migration-v2.creating.*' -print -quit
            )"

            corrupt_home="$TMPDIR/corrupt-home"
            mkdir -p "$corrupt_home/.local/bin"
            printf 'legacy\n' > "$corrupt_home/.local/bin/omp"
            if HOME="$corrupt_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-receipt \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            corrupt_pending="$corrupt_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending"
            printf 'invalid\treceipt\n' > "$corrupt_pending/receipt.tsv"
            if HOME="$corrupt_home" "$migration" prepare \
              > "$TMPDIR/corrupt.out" 2> "$TMPDIR/corrupt.err"; then
              exit 1
            fi
            grep -q 'unknown record' "$TMPDIR/corrupt.err"
            test -f "$corrupt_home/.local/bin/omp"

            dual_state_home="$TMPDIR/dual-state-home"
            mkdir -p "$dual_state_home/.local/bin"
            printf 'legacy\n' > "$dual_state_home/.local/bin/omp"
            if HOME="$dual_state_home" AGENT_TOOLS_MIGRATION_FAILPOINT=after-receipt \
              "$migration" prepare >/dev/null 2>&1; then
              exit 1
            fi
            mkdir "$dual_state_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"
            if HOME="$dual_state_home" "$migration" prepare \
              > "$TMPDIR/dual-state.out" 2> "$TMPDIR/dual-state.err"; then
              exit 1
            fi
            grep -q 'both pending and completed migration state exist' "$TMPDIR/dual-state.err"

            missing_backup_home="$TMPDIR/missing-backup-home"
            mkdir -p "$missing_backup_home/.local/bin"
            printf 'legacy\n' > "$missing_backup_home/.local/bin/omp"
            HOME="$missing_backup_home" "$migration" prepare
            rm "$missing_backup_home/.local/state/atyrode/agent-tools-migration/migration-v2.pending/backup/.local/bin/omp"
            if HOME="$missing_backup_home" "$migration" finalize "$empty_home_files" \
              > "$TMPDIR/missing-backup.out" 2> "$TMPDIR/missing-backup.err"; then
              exit 1
            fi
            grep -q 'planned backup' "$TMPDIR/missing-backup.err"

            legacy_home="$TMPDIR/legacy-home"
            mkdir -p "$legacy_home/.local/bin" "$legacy_home/.local/state/atyrode/agent-tools-migration"
            printf 'legacy binary\n' > "$legacy_home/.local/bin/omp"
            printf 'completed\n' > \
              "$legacy_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"
            HOME="$legacy_home" "$migration" prepare
            HOME="$legacy_home" "$migration" finalize "$empty_home_files"
            test -f "$legacy_home/.local/bin/omp"

            locked_home="$TMPDIR/locked-home"
            locked_state="$locked_home/.local/state/atyrode/agent-tools-migration"
            mkdir -p "$locked_home/.local/bin" "$locked_state"
            printf 'legacy\n' > "$locked_home/.local/bin/omp"
            exec 8< "$locked_state"
            flock -n 8
            if HOME="$locked_home" "$migration" prepare > "$TMPDIR/locked.out" 2> "$TMPDIR/locked.err"; then
              exit 1
            fi
            flock -u 8
            grep -q 'another agent tools migration is running' "$TMPDIR/locked.err"
            test -f "$locked_home/.local/bin/omp"

            lock_link_home="$TMPDIR/lock-link-home"
            lock_link_state="$lock_link_home/.local/state/atyrode/agent-tools-migration"
            mkdir -p "$lock_link_home/.local/bin" "$lock_link_state"
            printf 'legacy\n' > "$lock_link_home/.local/bin/omp"
            printf 'victim\n' > "$lock_link_home/victim"
            ln -s "$lock_link_home/victim" "$lock_link_state/migration-v2.lock"
            HOME="$lock_link_home" "$migration" prepare
            grep -q '^victim$' "$lock_link_home/victim"
            HOME="$lock_link_home" "$migration" finalize "$empty_home_files"

            mkdir "$out"
      '';

  # The terminal-viewing stack from the tui-visual-verification skill (#163):
  # tmux drives and captures the TUI under test, charm-freeze renders the ANSI
  # capture to PNG with the pinned render fonts. Exercise the whole pipeline so
  # a missing tool, a renamed nixpkgs attribute, or a dropped font file fails
  # the flake instead of the first agent verification run.
  agent-tools-terminal-viewing =
    pkgs.runCommand "check-agent-tools-terminal-viewing"
      {
        nativeBuildInputs = [
          pkgs.charm-freeze
          pkgs.tmux
        ];
      }
      ''
        tmux -V
        freeze --version

        # The exact font files the profile installs and freeze is pointed at.
        test -f ${pkgs.jetbrains-mono}/share/fonts/truetype/JetBrainsMono-Regular.ttf
        test -f ${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/SymbolsNerdFontMono-Regular.ttf

        # Render a truecolor frame carrying a Nerd Font PUA glyph end to end,
        # with the fonts exposed the way a user profile exposes them.
        export HOME="$TMPDIR"
        export XDG_DATA_HOME="$TMPDIR/share"
        mkdir -p "$XDG_DATA_HOME/fonts"
        ln -s ${pkgs.jetbrains-mono}/share/fonts/truetype/*.ttf "$XDG_DATA_HOME/fonts/"
        ln -s ${pkgs.nerd-fonts.symbols-only}/share/fonts/truetype/NerdFonts/Symbols/*.ttf "$XDG_DATA_HOME/fonts/"
        printf '\x1b[38;2;255;95;175mpill \xee\x82\xb6 glyph\x1b[0m\n' > frame.ansi
        freeze --language ansi frame.ansi -o frame.png \
          --font.family "JetBrains Mono,Symbols Nerd Font Mono"
        test -s frame.png

        mkdir "$out"
      '';
}
