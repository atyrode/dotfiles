{ lib, pkgs }:

let
  fixtures = import ./lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures)
    configuredStub
    defaultsConfig
    policyConfig
    stubOmp
    untrustedConfig
    yoloConfig
    ;
  settingsGuardExtension = ../omp/extensions/managed-settings-guard.ts;
  parallelWriteRule = ../omp/rules/parallel-write-isolation.md;
  ompRuntimeVersion = builtins.head (lib.splitString "-" (lib.getVersion pkgs.omp));
  codeEnvironmentStub = pkgs.writeShellScriptBin "code" ''
    if [[ -z "''${CODE_ENV_LOG:-}" ]]; then
      while (( $# )); do
        if [[ "$1" == --out ]]; then
          : > "$2"
          exit 0
        fi
        shift
      done
      exit 0
    fi
    {
      printf 'OMP_AUTH_BROKER_URL=%s\n' "''${OMP_AUTH_BROKER_URL-unset}"
      printf 'OMP_AUTH_BROKER_TOKEN=%s\n' "''${OMP_AUTH_BROKER_TOKEN-unset}"
      printf 'OMP_AUTH_BROKER_SNAPSHOT_CACHE=%s\n' "''${OMP_AUTH_BROKER_SNAPSHOT_CACHE-unset}"
      printf 'args=%s\n' "$*"
    } > "''${CODE_ENV_LOG:?}"
  '';
  configuredCodeStub = pkgs.callPackage ../pkgs/omp-configured {
    omp = stubOmp;
    code = codeEnvironmentStub;
  };
in
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
      test "''${raw_version##*/}" = "${ompRuntimeVersion}"

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
        test "''${command_version##*/}" = "${ompRuntimeVersion}"
      done
      # The eval tool advertises Python by default, so every configured OMP
      # launcher must carry a vanilla interpreter even with an empty host PATH.
      mkdir -p "$TMPDIR/python-home"
      ${pkgs.coreutils}/bin/env -i \
        HOME="$TMPDIR/python-home" \
        PATH=/nonexistent \
        ${pkgs.omp-configured}/bin/omp setup python --check >/dev/null
      # OMP auto-detects its built-in Go and TypeScript servers only when
      # their binaries are on PATH. Both LSP-capable launch paths must
      # provide them without relying on host or project tooling.
      for command in omp omp-managed; do
        gopls_log="$TMPDIR/$command-gopls"
        typescript_lsp_log="$TMPDIR/$command-typescript-language-server"
        ${pkgs.coreutils}/bin/env -i \
          HOME="$TMPDIR/python-home" \
          PATH=/nonexistent \
          GOPLS_STUB_LOG="$gopls_log" \
          TYPESCRIPT_LSP_STUB_LOG="$typescript_lsp_log" \
          ${configuredStub}/bin/"$command" --version >/dev/null
        grep -Fxq ${lib.escapeShellArg (lib.getExe configuredStub.goplsCommand)} "$gopls_log"
        grep -Fxq ${lib.escapeShellArg (lib.getExe pkgs.typescript-language-server)} \
          "$typescript_lsp_log"
      done
      ${pkgs.omp-configured}/bin/code --help > "$TMPDIR/code-help.txt"
      grep -q 'build an OMP profile from a prompt' "$TMPDIR/code-help.txt"
      grep -q 'v opens the' "$TMPDIR/code-help.txt"
      grep -q 'account manager' "$TMPDIR/code-help.txt"
      ! grep -q 'pick an OMP launcher' "$TMPDIR/code-help.txt"
      grep -q 'code ls' "$TMPDIR/code-help.txt"
      # `code ls` must survive the wrapper's tty guard. It exists for scripts
      # and for triaging a machine over a bare `ssh host 'code ls'`, which is
      # precisely when no terminal is attached — and a nix build sandbox has
      # none either, so this check reproduces that condition exactly.
      CODE_SESSION_STATE="$TMPDIR/code-sessions" \
        ${pkgs.omp-configured}/bin/code ls > "$TMPDIR/code-ls.txt"
      grep -Fq 'no live sessions' "$TMPDIR/code-ls.txt"
      # The generator owns only non-secret account/selection state; every
      # trusted child inherits the central broker and its launch account pool.
      grep -Fq 'export CODE_AUTH_ACCOUNT_STATE="''${CODE_AUTH_ACCOUNT_STATE:-''${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/code-auth-account-state.json}"' \
        ${pkgs.omp-configured}/bin/code
      grep -Fq 'export CODE_SELECTION_STATE="''${CODE_SELECTION_STATE:-''${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/code-generator-selection.json}"' \
        ${pkgs.omp-configured}/bin/code
      grep -Fq 'export CODE_OMP_RAW="$omp_bin"' ${pkgs.omp-configured}/bin/code
      grep -Fq 'export CODE_RUNTIME_BROKER="''${CODE_RUNTIME_BROKER:-atyrode}"' ${pkgs.omp-configured}/bin/code
      grep -Fq -- '--profile default usage --json' ${pkgs.omp-configured}/bin/code
      broker_state="$TMPDIR/code-broker-state/atyrode/omp-auth-broker"
      mkdir -p "$broker_state"
      printf 'broker-token\n' > "$broker_state/token"
      CODE_ENV_LOG="$TMPDIR/code-broker-env" \
        XDG_STATE_HOME="$TMPDIR/code-broker-state" \
        XDG_CACHE_HOME="$TMPDIR/code-broker-cache" \
        ${configuredCodeStub}/bin/code ls
      printf '%s\n' \
        'OMP_AUTH_BROKER_URL=http://127.0.0.1:46171' \
        'OMP_AUTH_BROKER_TOKEN=broker-token' \
        "OMP_AUTH_BROKER_SNAPSHOT_CACHE=$TMPDIR/code-broker-cache/atyrode/omp-auth-broker/snapshot.json" \
        'args=ls' > "$TMPDIR/expected-code-broker-env"
      cmp "$TMPDIR/expected-code-broker-env" "$TMPDIR/code-broker-env"

      rm "$broker_state/token"
      CODE_ENV_LOG="$TMPDIR/code-no-broker-env" \
        XDG_STATE_HOME="$TMPDIR/code-broker-state" \
        OMP_AUTH_BROKER_URL=stale-url \
        OMP_AUTH_BROKER_TOKEN= \
        OMP_AUTH_BROKER_SNAPSHOT_CACHE=stale-cache \
        ${configuredCodeStub}/bin/code ls
      printf '%s\n' \
        'OMP_AUTH_BROKER_URL=unset' \
        'OMP_AUTH_BROKER_TOKEN=unset' \
        'OMP_AUTH_BROKER_SNAPSHOT_CACHE=unset' \
        'args=ls' > "$TMPDIR/expected-code-no-broker-env"
      cmp "$TMPDIR/expected-code-no-broker-env" "$TMPDIR/code-no-broker-env"
      ! grep -Fq 'CODE_AUTH_VAULTS=' ${pkgs.omp-configured}/bin/code
      ! grep -Fq 'CODE_AUTH_PROFILES' ${pkgs.omp-configured}/bin/code
      ! grep -Fq 'code-auth-profiles.json' ${pkgs.omp-configured}/bin/code
      test ! -e ${pkgs.omp-configured}/bin/pi
      test "$(
        find ${pkgs.omp-configured}/bin -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | paste -sd, -
      )" = "code,omp,omp-managed,ompu"

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
        --arg version "${ompRuntimeVersion}" \
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
        throw new Error("upstream yaml fallback was not selected");
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

      test "$(
        find ${pkgs.omp-configured.platformRoot}/extensions -maxdepth 1 -name '*.ts' -printf '%f\n' | sort | paste -sd, -
      )" = "managed-settings-guard.ts,vault-usage-footer.ts"
      grep -q 'isolated: true' ${parallelWriteRule}

      test "$(
        find ${pkgs.omp-agents}/share/omp/agents -maxdepth 1 -name '*.md' | wc -l
      )" -eq 7
      test "$(find ${pkgs.omp-configured.platformRoot}/agents -maxdepth 1 -name '*.md' | wc -l)" -eq 7
      test -f ${pkgs.omp-configured.platformRoot}/extensions/managed-settings-guard.ts
      test -f ${pkgs.omp-configured.platformRoot}/extensions/vault-usage-footer.ts
      test -f ${pkgs.omp-configured.platformRoot}/rules/no-shell-text-surgery.md
      test -f ${pkgs.omp-configured.platformRoot}/rules/parallel-write-isolation.md

      mkdir "$out"
    ''
