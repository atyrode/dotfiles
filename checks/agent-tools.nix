{
  lib,
  pkgs,
}:

let
  baseConfig = ../omp/config.yml;
  budgetPreset = ../omp/presets/budget.yml;
  fablePreset = ../omp/presets/fable-primary.yml;
  gptPreset = ../omp/presets/gpt56.yml;
  opusPreset = ../omp/presets/opus-fallback.yml;

  stubOmp =
    pkgs.runCommand "omp-16.3.14-stub"
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

  stubBigpowers = pkgs.runCommand "bigpowers-stub" { } ''
    mkdir -p "$out/share/omp/plugins/bigpowers"
  '';

  configuredStub = pkgs.callPackage ../pkgs/omp-configured {
    bigpowers = stubBigpowers;
    omp = stubOmp;
  };
in
{
  omp-stack =
    pkgs.runCommand "check-omp-stack"
      {
        nativeBuildInputs = [
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
        test "''${raw_version##*/}" = "16.3.14"

        for config in \
          ${baseConfig} \
          ${budgetPreset} \
          ${fablePreset} \
          ${gptPreset}
        do
          "$raw_omp" models --config "$config" --json >/dev/null
        done

        "$raw_omp" models \
          --config ${baseConfig} \
          --config ${gptPreset} \
          --config ${opusPreset} \
          --json >/dev/null

        test "$(yq eval '.modelRoles.default' ${baseConfig})" = "openai-codex/gpt-5.6-terra:medium"
        test "$(yq eval '.tools.approvalMode' ${baseConfig})" = "write"
        test "$(yq eval '.secrets.enabled' ${baseConfig})" = "true"
        test "$(yq eval '.retry.modelFallback' ${fablePreset})" = "false"

        for command in omp ompb ompf ompg ompo; do
          command_version="$(${pkgs.omp-configured}/bin/"$command" --version)"
          test "''${command_version##*/}" = "16.3.14"
        done
        test "$(${pkgs.herdr-configured}/bin/herdr --version)" = "herdr 0.7.3"

        set +e
        ${pkgs.herdr-configured}/bin/herdr update > "$TMPDIR/herdr.out" 2> "$TMPDIR/herdr.err"
        herdr_update_status=$?
        set -e
        test "$herdr_update_status" -eq 2
        grep -q 'managed by Nix' "$TMPDIR/herdr.err"

        ${pkgs.omp-configured}/bin/omp models --json > "$TMPDIR/models.json" 2> "$TMPDIR/models.err"
        test ! -s "$TMPDIR/models.err"
        jq -e '.models | type == "array"' "$TMPDIR/models.json" >/dev/null

        jq -e '
          .name == "bigpowers" and
          .version == "2.76.2" and
          .pi.skills == ["./.pi/skills"] and
          .pi.prompts == ["./.pi/prompts"]
        ' ${pkgs.bigpowers}/share/omp/plugins/bigpowers/package.json >/dev/null
        test ! -e ${pkgs.bigpowers}/share/omp/plugins/bigpowers/.mcp.json
        test -f ${pkgs.bigpowers}/share/omp/plugins/bigpowers/.pi/skills/using-bigpowers/SKILL.md

        test "$(
          find ${pkgs.omp-agents}/share/omp/agents -maxdepth 1 -name '*.md' | wc -l
        )" -eq 13
        grep -q 'HERDR_INTEGRATION_ID=omp' \
          ${pkgs.herdr-omp-integration}/share/omp/extensions/herdr-omp-agent-state.ts

        mkdir "$out"
      '';

  omp-wrapper =
    pkgs.runCommand "check-omp-wrapper"
      {
        nativeBuildInputs = [ pkgs.diffutils ];
      }
      ''
            export HOME="$TMPDIR/home"
            export XDG_CONFIG_HOME="$HOME/.config"
            mkdir -p "$XDG_CONFIG_HOME/omp"
            printf 'custom: true\n' > "$XDG_CONFIG_HOME/omp/local.yml"

            ${configuredStub}/bin/ompo --model custom > "$TMPDIR/actual"
            cat > "$TMPDIR/expected" <<EOF
        --config
        ${toString baseConfig}
        --plugin-dir
        ${stubBigpowers}/share/omp/plugins/bigpowers
        --config
        $XDG_CONFIG_HOME/omp/local.yml
        --config
        ${toString gptPreset}
        --config
        ${toString opusPreset}
        --model
        custom
        EOF
            diff -u "$TMPDIR/expected" "$TMPDIR/actual"

            ${configuredStub}/bin/omp models --json > "$TMPDIR/actual"
            printf 'models\n--json\n' > "$TMPDIR/expected"
            diff -u "$TMPDIR/expected" "$TMPDIR/actual"

            set +e
            ${configuredStub}/bin/omp update > "$TMPDIR/update.out" 2> "$TMPDIR/update.err"
            update_status=$?
        ${configuredStub}/bin/omp plugin install bigpowers > "$TMPDIR/plugin.out" 2> "$TMPDIR/plugin.err"
        plugin_status=$?
        ${configuredStub}/bin/omp install --global bigpowers > "$TMPDIR/install.out" 2> "$TMPDIR/install.err"
        install_status=$?
        set -e

        test "$update_status" -eq 2
        test "$plugin_status" -eq 2
        test "$install_status" -eq 2
        grep -q 'managed by Nix' "$TMPDIR/update.err"
        grep -q 'managed by Nix' "$TMPDIR/plugin.err"
        grep -q 'managed by Nix' "$TMPDIR/install.err"

            mkdir "$out"
      '';

  agent-tools-migration =
    pkgs.runCommand "check-agent-tools-migration"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.yq-go
        ];
      }
      ''
            migration=${lib.escapeShellArg (lib.getExe pkgs.agent-tools-migrate)}
            export HOME="$TMPDIR/home"

            mkdir -p \
              "$HOME/.local/bin" \
              "$HOME/.omp/plugins/node_modules/bigpowers" \
              "$HOME/.omp/agent/agents" \
              "$HOME/.omp/agent/extensions" \
              "$HOME/.omp/agent/rules" \
              "$HOME/.omp/agent/managed-skills/ts-react-dead-code-sweep"

            cat > "$HOME/.local/bin/omp" <<'EOF'
        #!/bin/sh
        printf '%s\n' 'omp/16.3.14'
        EOF
            cat > "$HOME/.local/bin/herdr" <<'EOF'
        #!/bin/sh
        printf '%s\n' 'herdr 0.7.3'
        EOF
            chmod +x "$HOME/.local/bin/omp" "$HOME/.local/bin/herdr"

            cat > "$HOME/.omp/plugins/package.json" <<'EOF'
        {"dependencies":{"bigpowers":"2.76.2"}}
        EOF
            printf 'legacy\n' > "$HOME/.omp/agent/agents/task.md"
            printf 'legacy\n' > "$HOME/.omp/agent/extensions/herdr-omp-agent-state.ts"
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
        dev:
          autoqa:
            consent: accepted
        modelRoles:
          default: legacy/model
        retry:
          enabled: true
        tools:
          approvalMode: yolo
          custom: preserved
        secrets:
          enabled: false
          custom: preserved
        custom:
          nested: preserved
        EOF

            "$migration"

            state_root="$HOME/.local/state/atyrode/agent-tools-migration"
            backup_dir="$(find "$state_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

            test -n "$backup_dir"
            test -f "$state_root/migration-v2.complete"
            test -x "$backup_dir/.local/bin/omp"
            test -x "$backup_dir/.local/bin/herdr"
            test -f "$backup_dir/.omp/plugins/package.json"
            test -f "$backup_dir/.omp/agent/agents/task.md"
            test -f "$backup_dir/.omp/agent/extensions/herdr-omp-agent-state.ts"
            test -f "$backup_dir/.omp/agent/rules/no-shell-text-surgery.md"
            test -f "$backup_dir/.omp/agent/gpt56-only.yml"
            test -f "$backup_dir/.omp/agent/managed-skills/ts-react-dead-code-sweep/SKILL.md"
            test -f "$backup_dir/.omp/agent/mcp.json"
            test -f "$backup_dir/.omp/agent/config.yml"
            test ! -e "$HOME/.omp/agent/mcp.json"

            test "$(yq eval '.setupVersion' "$HOME/.omp/agent/config.yml")" = "7"
            test "$(yq eval '.dev.autoqa.consent' "$HOME/.omp/agent/config.yml")" = "accepted"
            test "$(yq eval '.custom.nested' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.modelRoles' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.retry' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.tools.approvalMode' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.tools.custom' "$HOME/.omp/agent/config.yml")" = "preserved"
            test "$(yq eval '.secrets.enabled' "$HOME/.omp/agent/config.yml")" = "null"
            test "$(yq eval '.secrets.custom' "$HOME/.omp/agent/config.yml")" = "preserved"

            backup_count="$(find "$state_root" -mindepth 1 -maxdepth 1 -type d | wc -l)"
            "$migration"
            test "$(find "$state_root" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq "$backup_count"

            dry_home="$TMPDIR/dry-home"
            mkdir -p "$dry_home/.local/bin"
            cp "$backup_dir/.local/bin/omp" "$dry_home/.local/bin/omp"
            HOME="$dry_home" AGENT_TOOLS_DRY_RUN=1 "$migration"
            test -x "$dry_home/.local/bin/omp"
            test ! -e "$dry_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"

            opaque_home="$TMPDIR/opaque-home"
            mkdir -p "$opaque_home/.local/bin"
            cat > "$opaque_home/.local/bin/omp" <<'EOF'
        #!/bin/sh
        touch "$HOME/executed"
        EOF
            chmod +x "$opaque_home/.local/bin/omp"

            HOME="$opaque_home" "$migration"
            opaque_state="$opaque_home/.local/state/atyrode/agent-tools-migration"
            opaque_backup="$(find "$opaque_state" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
            test ! -e "$opaque_home/executed"
            test -x "$opaque_backup/.local/bin/omp"
            test -f "$opaque_state/migration-v2.complete"

            custom_mcp_home="$TMPDIR/custom-mcp-home"
            mkdir -p "$custom_mcp_home/.omp/agent"
            cat > "$custom_mcp_home/.omp/agent/mcp.json" <<'EOF'
        {
          "mcpServers": {
            "custom": {
              "command": "custom-mcp"
            }
          },
          "disabledServers": ["bigpowers-mcp"]
        }
        EOF

            HOME="$custom_mcp_home" "$migration"
            jq -e '.mcpServers.custom.command == "custom-mcp"' \
              "$custom_mcp_home/.omp/agent/mcp.json" >/dev/null

            unsafe_home="$TMPDIR/unsafe-home"
            mkdir -p "$unsafe_home/.local/bin/omp"

            if HOME="$unsafe_home" "$migration" > "$TMPDIR/unsafe.out" 2> "$TMPDIR/unsafe.err"; then
              exit 1
            fi

            grep -q 'not a regular file or symlink' "$TMPDIR/unsafe.err"
            test -d "$unsafe_home/.local/bin/omp"
            test ! -e "$unsafe_home/.local/state/atyrode/agent-tools-migration/migration-v2.complete"

            mkdir "$out"
      '';
}
