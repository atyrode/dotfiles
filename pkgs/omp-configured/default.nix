{
  bash,
  cacert,
  coreutils,
  findutils,
  fzf,
  gawk,
  gitMinimal,
  gnugrep,
  jq,
  lib,
  herdr-omp-integration,
  omp,
  omp-agents,
  patch,
  python3,
  runCommand,
  writeShellApplication,
  yq-go,
}:

let
  defaultsConfig = ../../omp/defaults.yml;
  policyConfig = ../../omp/policy.yml;
  untrustedConfig = ../../omp/untrusted.yml;
  untrustedPrompt = builtins.readFile ../../omp/untrusted-system-prompt.md;
  yoloConfig = ../../omp/yolo-session.yml;
  neutralRoot = runCommand "omp-untrusted-neutral-root" { } ''
    mkdir "$out"
  '';
  platformRoot = runCommand "omp-managed-platform-${lib.getVersion omp}" { } ''
    mkdir -p "$out/agents" "$out/extensions" "$out/rules"
    cp ${omp-agents}/share/omp/agents/*.md "$out/agents/"
    cp ${herdr-omp-integration}/share/omp/extensions/herdr-omp-agent-state.ts "$out/extensions/"
    cp ${../../omp/extensions/managed-settings-guard.ts} "$out/extensions/managed-settings-guard.ts"
    cp ${../../omp/extensions/task-isolation-guard.ts} "$out/extensions/task-isolation-guard.ts"
    cp ${../../omp/rules/no-shell-text-surgery.md} "$out/rules/no-shell-text-surgery.md"
    cp ${../../omp/rules/untrusted-external-content.md} "$out/rules/untrusted-external-content.md"
    cat > "$out/package.json" <<'EOF'
    {
      "name": "atyrode-managed-omp-platform",
      "private": true,
      "type": "module",
      "omp": {
        "extensions": [
          "./extensions/herdr-omp-agent-state.ts",
          "./extensions/managed-settings-guard.ts",
          "./extensions/task-isolation-guard.ts"
        ]
      }
    }
    EOF
  '';
  presets = {
    budget = ../../omp/presets/budget.yml;
    fable = ../../omp/presets/fable-primary.yml;
    gpt = ../../omp/presets/gpt56.yml;
    sonnet = ../../omp/presets/sonnet-value.yml;
    claude = ../../omp/presets/claude-hard.yml;
    context = ../../omp/presets/context-1m.yml;
    fast = ../../omp/presets/fast-mixed.yml;
    gptSpeed = ../../omp/presets/gpt-speed.yml;
    claudeSpeed = ../../omp/presets/claude-speed.yml;
    mixedRegular = ../../omp/presets/mixed-regular.yml;
    mixedSmart = ../../omp/presets/mixed-smart.yml;
    gptOnly = ../../omp/presets/gpt-only.yml;
    claudeOnly = ../../omp/presets/claude-only.yml;
  };

  managedDefaultPaths = [
    "providers.webSearch"
    "symbolPreset"
    "colorBlindMode"
    "modelRoles"
    "retry.enabled"
    "retry.modelFallback"
    "retry.fallbackRevertPolicy"
    "retry.fallbackChains"
    "personality"
    "advisor.enabled"
    "advisor.subagents"
    "advisor.syncBacklog"
    "stt.enabled"
    "branchSummary.enabled"
    "autolearn.enabled"
    "autolearn.autoContinue"
    "github.enabled"
    "checkpoint.enabled"
    "statusLine.preset"
    "statusLine.compactThinkingLevel"
    "statusLine.transparent"
    "terminal.showProgress"
    "tui.tight"
    "display.shimmer"
    "display.showTokenUsage"
    "display.cacheMissMarker"
    "codexResets.autoRedeem"
    "task.showResolvedModelBadge"
    "task.agentModelOverrides"
    "task.disabledAgents"
    "memory.backend"
    "theme.dark"
    "browser.headless"
    "browser.enabled"
    "proseOnlyThinking"
    "defaultThinkingLevel"
  ];
  managedPresetPaths = [
    "providers.anthropic.serverSideFallback"
  ];
  enforcedPolicyPaths = [
    "tools.approvalMode"
    "tools.approval.bash"
    "tools.approval.eval"
    "tools.approval.browser"
    "tools.approval.task"
    "tools.approval.github"
    "secrets.enabled"
    "task.isolation.mode"
    "task.isolation.merge"
    "task.isolation.commits"
  ];
  managedOwnedPaths = managedDefaultPaths ++ managedPresetPaths;
  allManagedPaths = managedOwnedPaths ++ enforcedPolicyPaths;

  mkOmpCommand =
    name: presetConfigs:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        jq
        yq-go
      ];
      text = ''
        raw_omp=${lib.escapeShellArg (lib.getExe omp)}
        launcher=${lib.escapeShellArg name}
        defaults_config='${defaultsConfig}'
        policy_config='${policyConfig}'
        yolo_config='${yoloConfig}'
        platform_root='${platformRoot}'
        local_config="''${XDG_CONFIG_HOME:-$HOME/.config}/omp/local.yml"

        preset_configs=( ${lib.concatMapStringsSep " " (path: "'${path}'") presetConfigs} )
        managed_default_paths=( ${lib.escapeShellArgs managedDefaultPaths} )
        managed_preset_paths=( ${lib.escapeShellArgs managedPresetPaths} )
        enforced_policy_paths=( ${lib.escapeShellArgs enforcedPolicyPaths} )
        managed_default_paths_json=${lib.escapeShellArg (builtins.toJSON managedDefaultPaths)}
        managed_preset_paths_json=${lib.escapeShellArg (builtins.toJSON managedPresetPaths)}
        enforced_policy_paths_json=${lib.escapeShellArg (builtins.toJSON enforcedPolicyPaths)}
        all_managed_paths_json=${lib.escapeShellArg (builtins.toJSON allManagedPaths)}
        preset_paths_json=${lib.escapeShellArg (builtins.toJSON (map toString presetConfigs))}

        takes_required_value() {
          case "$1" in
            --alias|--api-key|--append-system-prompt|--approval-mode|--config|--cwd|--export|--extension|-e|--fork|--hook|--max-time|--mode|--model|--models|--plan|--plugin-dir|--profile|--provider|--provider-session-id|--session-dir|--skills|--slow|--smol|--system-prompt|--thinking|--tools)
              return 0
              ;;
            *)
              return 1
              ;;
          esac
        }

        takes_optional_value() {
          case "$1" in
            --resume|-r|--session)
              return 0
              ;;
            *)
              return 1
              ;;
          esac
        }

        is_known_boolean() {
          case "$1" in
            --advisor|--allow-home|--auto-approve|--continue|-c|--hide-thinking|--no-extensions|--no-lsp|--no-pty|--no-rules|--no-session|--no-skills|--no-title|--no-tools|--print|-p|--print-thoughts|--yolo)
              return 0
              ;;
            *)
              return 1
              ;;
          esac
        }

        is_known_subcommand() {
          case "$1" in
            __complete|acp|agents|auth-broker|auth-gateway|bench|commit|completions|config|dry-balance|gallery|gc|grep|grievances|install|join|models|plugin|read|say|search|setup|shell|ssh|stats|tiny-models|token|ttsr|update|usage|worktree)
              return 0
              ;;
            *)
              return 1
              ;;
          esac
        }

        paths_overlap() {
          local key="$1"
          local owner="$2"
          [[ "$key" == "$owner" || "$key" == "$owner".* || "$owner" == "$key".* ]]
        }

        contains_managed_path() {
          local key="$1"
          shift
          local candidate
          for candidate in "$@"; do
            if paths_overlap "$key" "$candidate"; then
              return 0
            fi
          done
          return 1
        }

        json_array() {
          if (( $# == 0 )); then
            printf '[]\n'
            return 0
          fi
          printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'
        }

        normalize_profile() {
          local raw="$1"
          local strict="$2"
          local value="$raw"
          value="''${value#"''${value%%[![:space:]]*}"}"
          value="''${value%"''${value##*[![:space:]]}"}"

          normalized_profile=""
          if [[ -z "$value" || "$value" == default ]]; then
            return 0
          fi
          if [[ "$value" == . || "$value" == .. || "$value" == *. ]] ||
            [[ ! "$value" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
            [[ "$value" =~ ^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$ ]]; then
            if [[ "$strict" == true ]]; then
              printf '%s\n' \
                "Error: Invalid OMP profile '$raw'. Profile names must match ^[a-z0-9][a-z0-9._-]{0,63}$, cannot be '.', '..', end in '.', or use a Windows reserved device name." >&2
            fi
            return 1
          fi
          normalized_profile="$value"
        }

        resolve_path_from_cwd() {
          local value="$1"
          local base="$2"
          case "$value" in
            "~") value="$HOME" ;;
            \~/*) value="$HOME/''${value:2}" ;;
            /*) ;;
            *) value="$base/$value" ;;
          esac
          if [[ -d "$value" ]]; then
            value="$(cd "$value" && pwd -P)"
          fi
          printf '%s\n' "$value"
        }

        discover_runtime_context() {
          launch_cwd="$PWD"
          if [[ -v OMP_PROFILE ]]; then
            active_profile="$OMP_PROFILE"
          elif [[ -v PI_PROFILE ]]; then
            active_profile="$PI_PROFILE"
          else
            active_profile=default
          fi
          runtime_approval_mode=""
          runtime_model=""
          runtime_thinking=""
          runtime_advisor=false
          runtime_smol="''${PI_SMOL_MODEL:-}"
          runtime_slow="''${PI_SLOW_MODEL:-}"
          runtime_plan="''${PI_PLAN_MODEL:-}"
          explicit_cwd=false
          allow_home=false

          local i arg
          for ((i = 0; i < ''${#original_args[@]}; i++)); do
            arg="''${original_args[$i]}"
            case "$arg" in
              --)
                break
                ;;
              --cwd=*)
                launch_cwd="''${arg#--cwd=}"
                explicit_cwd=true
                ;;
              --cwd)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  launch_cwd="''${original_args[$i]}"
                  explicit_cwd=true
                fi
                ;;
              --profile=*)
                active_profile="''${arg#--profile=}"
                ;;
              --profile)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  active_profile="''${original_args[$i]}"
                fi
                ;;
              --approval-mode=*)
                runtime_approval_mode="''${arg#--approval-mode=}"
                ;;
              --approval-mode)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  runtime_approval_mode="''${original_args[$i]}"
                fi
                ;;
              --auto-approve | --yolo)
                runtime_approval_mode=yolo
                ;;
              --model=*)
                runtime_model="''${arg#--model=}"
                ;;
              --model)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  runtime_model="''${original_args[$i]}"
                fi
                ;;
              --smol=*)
                runtime_smol="''${arg#--smol=}"
                ;;
              --smol)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  runtime_smol="''${original_args[$i]}"
                fi
                ;;
              --slow=*)
                runtime_slow="''${arg#--slow=}"
                ;;
              --slow)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  runtime_slow="''${original_args[$i]}"
                fi
                ;;
              --plan=*)
                runtime_plan="''${arg#--plan=}"
                ;;
              --plan)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  runtime_plan="''${original_args[$i]}"
                fi
                ;;
              --thinking=*)
                runtime_thinking="''${arg#--thinking=}"
                ;;
              --thinking)
                if (( i + 1 < ''${#original_args[@]} )); then
                  i=$((i + 1))
                  runtime_thinking="''${original_args[$i]}"
                fi
                ;;
              --advisor)
                runtime_advisor=true
                ;;
              --allow-home)
                allow_home=true
                ;;
              --*=*)
                ;;
              *)
                if takes_required_value "$arg"; then
                  if (( i + 1 < ''${#original_args[@]} )); then
                    i=$((i + 1))
                  fi
                elif takes_optional_value "$arg"; then
                  if (( i + 1 < ''${#original_args[@]} )) &&
                    [[ "''${original_args[$((i + 1))]}" != -* ]]; then
                    i=$((i + 1))
                  fi
                fi
                ;;
            esac
          done

          case "$launch_cwd" in
            /*) ;;
            *) launch_cwd="$PWD/$launch_cwd" ;;
          esac
          if [[ -d "$launch_cwd" ]]; then
            launch_cwd="$(cd "$launch_cwd" && pwd -P)"
          fi

          local canonical_home="$HOME"
          if [[ -d "$canonical_home" ]]; then
            canonical_home="$(cd "$canonical_home" && pwd -P)"
          fi
          if [[ "$explicit_cwd" == false && "$allow_home" == false && "$launch_cwd" == "$canonical_home" ]]; then
            local candidate fallback
            for candidate in "$HOME/tmp" /tmp /var/tmp; do
              if [[ -d "$candidate" ]]; then
                launch_cwd="$(cd "$candidate" && pwd -P)"
                break
              fi
            done
            if [[ "$launch_cwd" == "$canonical_home" ]]; then
              fallback="''${TMPDIR:-''${TMP:-''${TEMP:-/tmp}}}"
              if [[ -d "$fallback" ]]; then
                fallback="$(cd "$fallback" && pwd -P)"
                if [[ "$fallback" != "$canonical_home" ]]; then
                  launch_cwd="$fallback"
                fi
              fi
            fi
          fi

          project_settings="$launch_cwd/.omp/settings.json"
          project_config="$launch_cwd/.omp/config.yml"
          if ! normalize_profile "$active_profile" true; then
            exit 1
          fi
          active_profile="$normalized_profile"
          if [[ -z "$active_profile" ]]; then
            active_profile=default
            local inherited_profile=""
            if normalize_profile "''${PI_PROFILE:-}" false; then
              inherited_profile="$normalized_profile"
            fi
            local config_root="$HOME/''${PI_CONFIG_DIR:-.omp}"
            local inherited_agent_dir=""
            if [[ -n "$inherited_profile" ]]; then
              inherited_agent_dir="$config_root/profiles/$inherited_profile/agent"
            fi
            if [[ -n "''${PI_CODING_AGENT_DIR:-}" && "$PI_CODING_AGENT_DIR" != "$inherited_agent_dir" ]]; then
              state_path="$PI_CODING_AGENT_DIR"
              case "$state_path" in
                "~") state_path="$HOME" ;;
                \~/*) state_path="$HOME/''${state_path:2}" ;;
                /*) ;;
                *) state_path="$PWD/$state_path" ;;
              esac
            else
              state_path="$config_root/agent"
            fi
          else
            state_path="$HOME/''${PI_CONFIG_DIR:-.omp}/profiles/$active_profile/agent"
          fi
          if [[ -d "$state_path" ]]; then
            state_path="$(cd "$state_path" && pwd -P)"
          fi
          machine_config="$state_path/config.yml"
          if [[ ! -e "$machine_config" && -e "$state_path/config.yaml" ]]; then
            machine_config="$state_path/config.yaml"
          fi
        }

        subcommand=""
        subcommand_index=-1

        classify_invocation() {
          local -a argv=( "$@" )
          local i=0
          local arg flag next

          while (( i < ''${#argv[@]} )); do
            arg="''${argv[$i]}"

            case "$arg" in
              --)
                return 0
                ;;
              --help|-h|--version|-v)
                subcommand="__passthrough__"
                return 0
                ;;
            esac

            if [[ "$arg" == --*=* ]]; then
              flag="''${arg%%=*}"
              if takes_required_value "$flag" || takes_optional_value "$flag"; then
                i=$((i + 1))
                continue
              fi
            fi

            if takes_required_value "$arg"; then
              if (( i + 1 >= ''${#argv[@]} )); then
                return 0
              fi
              i=$((i + 2))
              continue
            fi

            if takes_optional_value "$arg"; then
              next="''${argv[$((i + 1))]:-}"
              if [[ -n "$next" && "$next" != -* ]]; then
                i=$((i + 2))
              else
                i=$((i + 1))
              fi
              continue
            fi

            if is_known_boolean "$arg"; then
              i=$((i + 1))
              continue
            fi

            if is_known_subcommand "$arg"; then
              subcommand="$arg"
              subcommand_index="$i"
              return 0
            fi

            # The first unknown flag or positional belongs to a root session.
            return 0
          done
        }

        normalize_layer_json() {
          local file="$1"
          yq eval -o=json -I=0 '.' "$file" | jq -c '
            if (.theme | type) == "string" then
              if .theme == "light" or .theme == "dark" then
                del(.theme)
              else
                .theme = { dark: .theme }
              end
            else . end
            | if (.codexResets | type) == "object" and (.codexResets.autoRedeem | type) == "boolean" then
                .codexResets.autoRedeem = (if .codexResets.autoRedeem then "yes" else "no" end)
              else . end
            | if (."codexResets.autoRedeem" | type) == "boolean" then
                ."codexResets.autoRedeem" = (if ."codexResets.autoRedeem" then "yes" else "no" end)
              else . end
            | if (.memory | type) != "object" then .memory = {} else . end
            | if ((.memory.backend | type) != "string")
                and ((.memories | type) == "object")
                and ((.memories.enabled | type) == "boolean") then
                .memory.backend = (if .memories.enabled then "local" else "off" end)
              else . end
            | if .memory.backend == "mnemosyne" then .memory.backend = "mnemopi" else . end
            | if (.memory | length) == 0 then del(.memory) else . end
            | if ((.task | type) == "object")
                and ((.task.isolation | type) == "object")
                and ((.task.isolation.enabled | type) == "boolean") then
                .task.isolation.mode = (if .task.isolation.enabled then "auto" else "none" end)
                | del(.task.isolation.enabled)
              else . end
            | if (try .task.isolation.mode catch null) == "worktree" then .task.isolation.mode = "rcopy"
              elif (try .task.isolation.mode catch null) == "fuse-overlay" then .task.isolation.mode = "overlayfs"
              elif (try .task.isolation.mode catch null) == "fuse-projfs" then .task.isolation.mode = "projfs"
              else . end
          '
        }

        emit_managed_config() {
          local json_output="$1"
          local local_present=false
          local machine_present=false
          local project_settings_present=false
          local project_config_present=false
          local -a layer_files=()
          local preset

          if [[ -e "$machine_config" ]]; then
            machine_present=true
            layer_files+=( "$machine_config" )
          fi
          layer_files+=( "$defaults_config" )
          if [[ -e "$project_settings" ]]; then
            project_settings_present=true
            layer_files+=( "$project_settings" )
          fi
          if [[ -e "$project_config" ]]; then
            project_config_present=true
            layer_files+=( "$project_config" )
          fi

          if [[ -f "$local_config" ]]; then
            local_present=true
            layer_files+=( "$local_config" )
          fi
          for preset in "''${preset_configs[@]}"; do
            layer_files+=( "$preset" )
          done
          extract_one_shot_configs "''${original_args[@]}"
          local one_shot
          local -a resolved_one_shot_configs=()
          for one_shot in "''${one_shot_configs[@]}"; do
            one_shot="$(resolve_path_from_cwd "$one_shot" "$launch_cwd")"
            resolved_one_shot_configs+=( "$one_shot" )
            layer_files+=( "$one_shot" )
          done
          layer_files+=( "$policy_config" )
          if [[ "$runtime_approval_mode" == yolo ]]; then
            layer_files+=( "$yolo_config" )
          fi

          local merged_json effective_managed policy_json diagnostic_json one_shots_json runtime_overrides
          local runtime_yolo=false
          if [[ "$runtime_approval_mode" == yolo ]]; then
            runtime_yolo=true
          fi
          merged_json='{}'
          local layer_json layer_file
          for layer_file in "''${layer_files[@]}"; do
            layer_json="$(normalize_layer_json "$layer_file")"
            merged_json="$(printf '%s\n%s\n' "$merged_json" "$layer_json" | jq -cs '.[0] * .[1]')"
          done
          effective_managed="$(
            # shellcheck disable=SC2016
            jq -c --argjson paths "$all_managed_paths_json" '
              . as $source
              | reduce $paths[] as $key ({};
                  ($key | split(".")) as $path
                  | (try ($source | getpath($path)) catch null) as $value
                  | if $value == null then . else setpath($path; $value) end
                )
            ' <<<"$merged_json"
          )"
          runtime_overrides="$(
            jq -n \
              --arg approvalMode "$runtime_approval_mode" \
              --arg model "$runtime_model" \
              --arg thinking "$runtime_thinking" \
              --arg smol "$runtime_smol" \
              --arg slow "$runtime_slow" \
              --arg plan "$runtime_plan" \
              --argjson unattended "$runtime_yolo" \
              --argjson advisor "$runtime_advisor" '
                {
                  approvalMode: (if $approvalMode == "" then null else $approvalMode end),
                  model: (if $model == "" then null else $model end),
                  thinking: (if $thinking == "" then null else $thinking end),
                  smol: (if $smol == "" then null else $smol end),
                  slow: (if $slow == "" then null else $slow end),
                  plan: (if $plan == "" then null else $plan end),
                  unattended: (if $unattended then true else null end),
                  advisor: (if $advisor then true else null end)
                }
                | with_entries(select(.value != null))
              '
          )"
          if [[ -n "$runtime_approval_mode" ]]; then
            effective_managed="$(
              jq -c --arg value "$runtime_approval_mode" '.tools.approvalMode = $value' <<<"$effective_managed"
            )"
          fi
          if [[ -n "$runtime_thinking" ]]; then
            effective_managed="$(
              jq -c --arg value "$runtime_thinking" '.defaultThinkingLevel = $value' <<<"$effective_managed"
            )"
          fi
          if [[ "$runtime_advisor" == true ]]; then
            effective_managed="$(jq -c '.advisor.enabled = true' <<<"$effective_managed")"
          fi
          if [[ -n "$runtime_model" ]]; then
            effective_managed="$(jq -c --arg value "$runtime_model" '.modelRoles.default = $value' <<<"$effective_managed")"
          fi
          if [[ -n "$runtime_smol" ]]; then
            effective_managed="$(jq -c --arg value "$runtime_smol" '.modelRoles.smol = $value' <<<"$effective_managed")"
          fi
          if [[ -n "$runtime_slow" ]]; then
            effective_managed="$(jq -c --arg value "$runtime_slow" '.modelRoles.slow = $value' <<<"$effective_managed")"
          fi
          if [[ -n "$runtime_plan" ]]; then
            effective_managed="$(jq -c --arg value "$runtime_plan" '.modelRoles.plan = $value' <<<"$effective_managed")"
          fi
          policy_json="$(yq eval -o=json -I=0 '.' "$policy_config")"
          one_shots_json="$(json_array "''${resolved_one_shot_configs[@]}")"

          diagnostic_json="$(
            # shellcheck disable=SC2016
            jq -n \
              --arg launcher "$launcher" \
              --arg profile "$active_profile" \
              --arg statePath "$state_path" \
              --arg effectiveCwd "$launch_cwd" \
              --arg machine "$machine_config" \
              --argjson machinePresent "$machine_present" \
              --arg defaults "$defaults_config" \
              --arg projectSettings "$project_settings" \
              --argjson projectSettingsPresent "$project_settings_present" \
              --arg project "$project_config" \
              --argjson projectConfigPresent "$project_config_present" \
              --arg local "$local_config" \
              --argjson localPresent "$local_present" \
              --arg policy "$policy_config" \
              --arg yolo "$yolo_config" \
              --argjson runtimeYolo "$runtime_yolo" \
              --argjson presets "$preset_paths_json" \
              --argjson oneShots "$one_shots_json" \
              --argjson defaultKeys "$managed_default_paths_json" \
              --argjson presetKeys "$managed_preset_paths_json" \
              --argjson policyKeys "$enforced_policy_paths_json" \
              --argjson effectiveManaged "$effective_managed" \
              --argjson enforcedPolicy "$policy_json" \
              --argjson runtimeOverrides "$runtime_overrides" '
                {
                  launcher: $launcher,
                  profile: $profile,
                  statePath: $statePath,
                  effectiveCwd: $effectiveCwd,
                  sources: (
                    [
                      { kind: "writable-machine-state", managed: false, implicit: true, path: $machine, present: $machinePresent },
                      { kind: "managed-defaults", managed: true, path: $defaults },
                      { kind: "native-project", format: "settings.json", managed: false, path: $projectSettings, present: $projectSettingsPresent },
                      { kind: "native-project", format: "config.yml", managed: false, path: $project, present: $projectConfigPresent },
                      { kind: "machine-local", managed: false, path: $local, present: $localPresent }
                    ]
                    + ($presets | map({ kind: "preset", managed: true, path: . }))
                    + ($oneShots | map({ kind: "one-shot-config", managed: false, invocationSpecific: true, path: . }))
                    + [
                      { kind: "managed-policy", managed: true, enforced: true, path: $policy }
                    ]
                    + (if $runtimeYolo then [
                      { kind: "one-session-unattended-policy", managed: true, invocationSpecific: true, path: $yolo }
                    ] else [] end)
                    + [
                      { kind: "runtime-flags", managed: false, invocationSpecific: true, overrides: $runtimeOverrides }
                    ]
                  ),
                  ownership: {
                    defaults: $defaultKeys,
                    presets: $presetKeys,
                    policy: $policyKeys
                  },
                  effectiveManaged: $effectiveManaged,
                  enforcedPolicy: $enforcedPolicy,
                  runtimeOverrides: $runtimeOverrides
                }
              '
          )"

          if [[ "$json_output" == true ]]; then
            jq '.' <<<"$diagnostic_json"
            return 0
          fi

          printf 'Managed OMP configuration (%s)\n\nSource order:\n' "$launcher"
          jq -r '
            .sources
            | to_entries[]
            | "  \(.key + 1). \(.value.kind)"
              + (if .value.path then " - " + .value.path else "" end)
              + (if .value.present == false then " (not present)" else "" end)
          ' <<<"$diagnostic_json"
          printf '\nEffective managed settings:\n'
          jq '.effectiveManaged' <<<"$diagnostic_json"
        }

        handle_config_command() {
          local -a positionals=()
          local json_output=false
          local show_help=false
          local unsupported_flag=""
          local after_separator=false
          local i arg

          for ((i = subcommand_index + 1; i < ''${#original_args[@]}; i++)); do
            arg="''${original_args[$i]}"
            if [[ "$after_separator" == true ]]; then
              positionals+=( "$arg" )
              continue
            fi
            case "$arg" in
              --)
                after_separator=true
                ;;
              --json)
                json_output=true
                ;;
              --help|-h)
                show_help=true
                ;;
              -*)
                unsupported_flag="$arg"
                ;;
              *)
                positionals+=( "$arg" )
                ;;
            esac
          done

          local action="''${positionals[0]:-list}"
          local key="''${positionals[1]:-}"

          if [[ "$action" == managed ]]; then
            if [[ "$show_help" == true ]]; then
              printf 'Usage: omp config managed [--json]\n'
              exit 0
            fi
            if [[ -n "$unsupported_flag" || ''${#positionals[@]} -ne 1 ]]; then
              printf 'Usage: omp config managed [--json]\n' >&2
              exit 2
            fi
            emit_managed_config "$json_output"
            exit 0
          fi

          if [[ "$action" == set || "$action" == reset ]]; then
            if contains_managed_path "$key" "''${enforced_policy_paths[@]}"; then
              printf '%s\n' \
                "OMP setting '$key' is enforced by Nix policy. Edit the dotfiles policy and run zconf; machine, project, preset, and --config values are intentionally shadowed." >&2
              exit 2
            fi
            if contains_managed_path "$key" "''${managed_default_paths[@]}"; then
              printf '%s\n' \
                "OMP setting '$key' is a Nix-managed default. Edit the dotfiles defaults, or override it in $local_config, then run zconf." >&2
              exit 2
            fi
            if contains_managed_path "$key" "''${managed_preset_paths[@]}"; then
              printf '%s\n' \
                "OMP setting '$key' is owned by a Nix-managed preset. Edit the preset or choose a launcher that does not select it, then run zconf." >&2
              exit 2
            fi
          fi

          if [[ "$action" == get ]] &&
            { contains_managed_path "$key" "''${enforced_policy_paths[@]}" ||
              contains_managed_path "$key" "''${managed_default_paths[@]}"; }; then
            printf '%s\n' \
              "OMP setting '$key' has Nix-managed layers. 'omp config get' only reads writable machine state; use 'omp config managed --json' for the effective value." >&2
            exit 2
          fi
          if [[ "$action" == get ]] && contains_managed_path "$key" "''${managed_preset_paths[@]}"; then
            printf '%s\n' \
              "OMP setting '$key' is owned by a Nix-managed preset. 'omp config get' only reads writable machine state; use 'omp config managed --json' for the effective value." >&2
            exit 2
          fi

          if [[ "$action" == list ]]; then
            printf '%s\n' \
              "Note: 'omp config list' shows writable machine state, not Nix overlays. Use 'omp config managed' for effective managed values." >&2
          fi

          exec "$raw_omp" "''${original_args[@]}"
        }

        extract_one_shot_configs() {
          one_shot_configs=()
          session_args=()
          local -a argv=( "$@" )
          local i=0
          local arg next
          local after_separator=false

          while (( i < ''${#argv[@]} )); do
            arg="''${argv[$i]}"
            if [[ "$after_separator" == true ]]; then
              session_args+=( "$arg" )
              i=$((i + 1))
              continue
            fi
            if [[ "$arg" == -- ]]; then
              after_separator=true
              session_args+=( "$arg" )
              i=$((i + 1))
              continue
            fi
            if [[ "$arg" == --config=* ]]; then
              one_shot_configs+=( "''${arg#--config=}" )
              i=$((i + 1))
              continue
            fi
            if [[ "$arg" == --config ]]; then
              if (( i + 1 >= ''${#argv[@]} )); then
                printf '%s\n' 'OMP --config requires a path.' >&2
                return 2
              fi
              one_shot_configs+=( "''${argv[$((i + 1))]}" )
              i=$((i + 2))
              continue
            fi
            if takes_required_value "$arg"; then
              session_args+=( "$arg" )
              if (( i + 1 < ''${#argv[@]} )); then
                session_args+=( "''${argv[$((i + 1))]}" )
                i=$((i + 2))
              else
                i=$((i + 1))
              fi
              continue
            fi
            if takes_optional_value "$arg"; then
              session_args+=( "$arg" )
              next="''${argv[$((i + 1))]:-}"
              if [[ -n "$next" && "$next" != -* ]]; then
                session_args+=( "$next" )
                i=$((i + 2))
              else
                i=$((i + 1))
              fi
              continue
            fi
            session_args+=( "$arg" )
            i=$((i + 1))
          done
        }

        original_args=( "$@" )
        classify_invocation "''${original_args[@]}"
        discover_runtime_context

        case "$subcommand" in
          __passthrough__)
            exec "$raw_omp" "''${original_args[@]}"
            ;;
          update)
            printf '%s\n' 'OMP is managed by Nix. Update the pinned derivation, then run zconf.' >&2
            exit 2
            ;;
          config)
            handle_config_command
            ;;
          setup)
            printf '%s\n' \
              "Note: 'omp setup' writes writable machine state. Nix-owned values remain governed by managed overlays; use 'omp config managed' afterward to inspect the effective session." >&2
            exec "$raw_omp" "''${original_args[@]}"
            ;;
          acp|"")
            ;;
          *)
            exec "$raw_omp" "''${original_args[@]}"
            ;;
        esac

        for arg in "''${original_args[@]}"; do
          if [[ "$arg" == --no-extensions ]]; then
            printf '%s\n' \
              'OMP --no-extensions is unavailable for managed sessions because it disables the Nix-owned settings guard, agents, rules, and Herdr integration. Use a dedicated restricted launcher instead.' >&2
            exit 2
          fi
        done

        launch_args=()
        if [[ "$subcommand" == acp ]]; then
          for ((i = 0; i < ''${#original_args[@]}; i++)); do
            if (( i != subcommand_index )); then
              launch_args+=( "''${original_args[$i]}" )
            fi
          done
        else
          launch_args=( "''${original_args[@]}" )
        fi

        extract_one_shot_configs "''${launch_args[@]}"

        managed_args=( --extension "$platform_root" --config "$defaults_config" )
        if [[ -e "$project_settings" ]]; then
          managed_args+=( --config "$project_settings" )
        fi
        if [[ -e "$project_config" ]]; then
          managed_args+=( --config "$project_config" )
        fi
        if [[ -f "$local_config" ]]; then
          managed_args+=( --config "$local_config" )
        fi
        for preset in "''${preset_configs[@]}"; do
          managed_args+=( --config "$preset" )
        done
        for one_shot in "''${one_shot_configs[@]}"; do
          managed_args+=( --config "$one_shot" )
        done
        managed_args+=( --config "$policy_config" )
        if [[ "$runtime_approval_mode" == yolo ]]; then
          printf '%s\n' \
            'WARNING: OMP unattended yolo mode is enabled for this process only. Tool approvals are bypassed; this is not an OS sandbox.' >&2
          managed_args+=( --config "$yolo_config" )
        fi

        if [[ "$subcommand" == acp ]]; then
          exec "$raw_omp" acp "''${managed_args[@]}" "''${session_args[@]}"
        fi
        exec "$raw_omp" "''${managed_args[@]}" "''${session_args[@]}"
      '';
    };

  ompDefault = writeShellApplication {
    name = "omp";
    text = ''
      if [[ "''${1:-}" == update ]]; then
        printf '%s\n' 'OMP is managed by Nix. Update the pinned derivation, then run zconf.' >&2
        exit 2
      fi
      exec ${lib.getExe omp} "$@"
    '';
  };
  ompBudget = mkOmpCommand "ompb" [ presets.budget ];
  ompSonnet = mkOmpCommand "omps" [ presets.sonnet ];
  ompFable = mkOmpCommand "ompf" [ presets.fable ];
  ompGpt = mkOmpCommand "ompg" [ presets.gpt ];
  ompClaude = mkOmpCommand "ompc" [ presets.claude ];
  ompContext = mkOmpCommand "ompx" [ presets.context ];
  ompFast = mkOmpCommand "ompz" [ presets.fast ];
  ompGptSpeed = mkOmpCommand "ompl" [ presets.gptSpeed ];
  ompClaudeSpeed = mkOmpCommand "ompk" [ presets.claudeSpeed ];
  ompMixedRegular = mkOmpCommand "ompn" [ presets.mixedRegular ];
  ompMixedSmart = mkOmpCommand "ompm" [ presets.mixedSmart ];
  ompGptOnly = mkOmpCommand "ompo" [ presets.gptOnly ];
  ompClaudeOnly = mkOmpCommand "ompe" [ presets.claudeOnly ];

  # Single source of truth for the launcher palette, ordered into soft groups
  # (mixed, then gpt-led, then claude-led, then specialists) and faster -> smarter
  # within each. The `code` picker lists every entry and labels the groups; `omph`
  # renders the routing for the preset-backed ones (those carrying a `preset`).
  # `omp`/`ompu` are special builders (no preset), shown in the picker only.
  paletteProfiles = [
    {
      cmd = "omp";
      exe = lib.getExe ompDefault;
      lead = "yours";
      group = "";
      blurb = "Your unmanaged ~/.omp config";
      detail = "Runs upstream OMP with whatever your writable ~/.omp config selects. No managed defaults, preset, or policy overlay beyond the blocked update.";
    }
    {
      cmd = "ompz";
      exe = lib.getExe ompFast;
      lead = "mixed";
      group = "mix";
      blurb = "Luna + Haiku, low thinking";
      detail = "The fastest competent tiers across both providers at low thinking — Luna and Spark on the GPT side, Sonnet and Haiku on the Claude side — with light single-hop crosses. For snappy interactive work; nothing reaches for Sol/Fable/Opus.";
      preset = presets.fast;
    }
    {
      cmd = "ompn";
      exe = lib.getExe ompMixedRegular;
      lead = "mixed";
      group = "mix";
      blurb = "Claude judges, GPT executes";
      detail = "Both pools at medium thinking: Claude leads judgment (default/design/review/plan), GPT leads execution (task/librarian/slow), Spark drains in the background. Full same-bucket-then-cross redundancy on every substantive role.";
      preset = presets.mixedRegular;
    }
    {
      cmd = "ompm";
      exe = lib.getExe ompMixedSmart;
      lead = "mixed";
      group = "mix";
      blurb = "Best model per task";
      detail = "The best model per task at high thinking: Sol drives GPT-strength roles, Fable/Opus the Claude-strength ones (design, planning, review). Full redundancy; Fable never an automatic net. When only the best will do, from either provider.";
      preset = presets.mixedSmart;
    }
    {
      cmd = "ompl";
      exe = lib.getExe ompGptSpeed;
      lead = "openai";
      group = "gpt";
      blurb = "Luna; task drains Spark";
      detail = "Luna leads at low thinking, task drains the free Spark bucket, and fallbacks are single fast hops to Haiku. Latency-first Codex; nothing reaches for Sol or high thinking. ompz's pure-GPT sibling.";
      preset = presets.gptSpeed;
    }
    {
      cmd = "ompb";
      exe = lib.getExe ompBudget;
      lead = "openai";
      group = "gpt";
      blurb = "Terra, off the premium tiers";
      detail = "Terra leads routine Codex work, kept off the premium tiers — failovers stay on Luna/Terra + Haiku/Sonnet, never Sol/Opus. Background drains Spark. The cost-conscious middle of the GPT lane.";
      preset = presets.budget;
    }
    {
      cmd = "ompg";
      exe = lib.getExe ompGpt;
      lead = "openai";
      group = "gpt";
      blurb = "Sol drives, Claude is the net";
      detail = "Sol leads the deliberative roles; a GPT sibling absorbs a capacity blip, then every substantive chain crosses to Opus/Sonnet. task/background drain Spark. All-OpenAI lead pool.";
      preset = presets.gpt;
    }
    {
      cmd = "ompo";
      exe = lib.getExe ompGptOnly;
      lead = "openai";
      group = "gpt";
      blurb = "Codex only, never crosses";
      detail = "Pure Codex: Sol drives, redundancy stays inside the bucket (Sol → Terra → Luna), background drains Spark. Keeps every token on OpenAI — for draining Codex, or when the Claude plan is down or off-limits.";
      preset = presets.gptOnly;
    }
    {
      cmd = "ompk";
      exe = lib.getExe ompClaudeSpeed;
      lead = "claude";
      group = "claude";
      blurb = "Haiku, fast and cheap";
      detail = "Haiku leads at low thinking, background drains the free Spark bucket, and fallbacks are single fast hops to Luna. Latency-first Claude — Haiku's home.";
      preset = presets.claudeSpeed;
    }
    {
      cmd = "omps";
      exe = lib.getExe ompSonnet;
      lead = "claude";
      group = "claude";
      blurb = "Sonnet value, Opus for depth";
      detail = "Sonnet 5 (intro pricing) leads all but plan/slow, where Opus earns its leverage. Every substantive chain is sibling-first, then crosses to Terra/Sol. Background drains Spark, then Haiku. All-Anthropic lead pool.";
      preset = presets.sonnet;
    }
    {
      cmd = "ompc";
      exe = lib.getExe ompClaude;
      lead = "claude";
      group = "claude";
      blurb = "Fable drives, Opus reviews";
      detail = "ompg's mirror. Fable drives, Opus is the sibling (and leads review), Sonnet/Haiku carry workers, every chain reaches back to Sol/Terra. Load this when OpenAI is dark or the Codex meter is empty and the work is hard.";
      preset = presets.claude;
    }
    {
      cmd = "ompe";
      exe = lib.getExe ompClaudeOnly;
      lead = "claude";
      group = "claude";
      blurb = "Claude only, never crosses";
      detail = "Pure Anthropic: Opus drives, redundancy stays inside the Claude plan (Opus → Sonnet → Haiku), never touching the separate Spark/Fable buckets. Keeps every token on Anthropic — for draining the plan, or when Codex is down.";
      preset = presets.claudeOnly;
    }
    {
      cmd = "ompf";
      exe = lib.getExe ompFable;
      lead = "claude";
      group = "special";
      blurb = "Fable, deterministic (no net)";
      detail = "Fable for the primary and deliberative roles with retry and server-side fallback OFF. The contract is: give me Fable, predictably, never silently swap. Background on cheap OpenAI rungs.";
      preset = presets.fable;
    }
    {
      cmd = "ompx";
      exe = lib.getExe ompContext;
      lead = "claude";
      group = "special";
      blurb = "Beyond 372K — Anthropic 1M";
      detail = "For work beyond the 372K ceiling. Anthropic's 1M line (Fable/Opus/Sonnet) leads and is the only redundancy — no OpenAI model runs 1M on a ChatGPT account, so there is no cross-net. Background trivia drains Spark, then Luna, then Haiku.";
      preset = presets.context;
    }
    {
      cmd = "ompu";
      exe = lib.getExe ompUntrusted;
      lead = "untrusted";
      group = "special";
      blurb = "Sandboxed, restricted tools";
      detail = "Dedicated sanitized state, stripped credentials, restricted tools and approvals for deliberately untrusted repositories. Inherits the managed defaults routing.";
    }
  ];
  presetProfiles = builtins.filter (p: p ? preset) paletteProfiles;
  ompuProfile = lib.findFirst (p: p.cmd == "ompu") (throw "ompu missing from palette") paletteProfiles;
  # ompu loads defaultsConfig then untrusted.yml, and untrusted.yml overrides only
  # tools/approvals — never modelRoles/retry/thinking — so its routing is exactly the
  # managed defaults. Render it like any preset so the picker preview and omph show a
  # real model list (GUI parity) instead of a blank. (The bare `omp` genuinely has no
  # managed routing — upstream's built-in modelRoles is empty — so it stays off this list.)
  routeSpecs =
    (map (p: "${p.cmd}|${p.blurb}|${p.preset}") presetProfiles)
    ++ [ "ompu|${ompuProfile.blurb}|${untrustedConfig}" ];
  routesHelp =
    runCommand "omp-routes-help-${lib.getVersion omp}"
      {
        nativeBuildInputs = [
          jq
          yq-go
        ];
      }
      ''
        mkdir -p "$out/share/omp"
        OMP_ROUTES_COLOR=1 bash ${./render-omp-routes.sh} '${lib.getVersion omp}' \
          ${omp-agents}/share/omp/agents ${defaultsConfig} \
          ${lib.escapeShellArgs routeSpecs} > "$out/share/omp/routes.ansi"
        OMP_ROUTES_COLOR=0 bash ${./render-omp-routes.sh} '${lib.getVersion omp}' \
          ${omp-agents}/share/omp/agents ${defaultsConfig} \
          ${lib.escapeShellArgs routeSpecs} > "$out/share/omp/routes.plain"
      '';
  # First-principles facet grid: the generator (a models.yml + routing rules,
  # see generate-profiles.py) emits a rendered routing block for every valid
  # (lane, model-tier, thinking, spark, fable) combination, baked at build time
  # so the generator view stays immutable and reviewable like the presets.
  generatedProfiles =
    runCommand "omp-generated-profiles" { nativeBuildInputs = [ python3 ]; }
      ''
        mkdir -p "$out/share/omp"
        python3 ${./generate-profiles.py} > "$out/share/omp/generated.plain"
      '';
  ompHelp = writeShellApplication {
    name = "omph";
    text = ''
      if [[ -t 1 && -z ''${NO_COLOR:-} ]]; then
        exec cat ${routesHelp}/share/omp/routes.ansi
      fi
      exec cat ${routesHelp}/share/omp/routes.plain
    '';
  };
  trustedUntrustedPath = lib.makeBinPath [
    bash
    coreutils
    findutils
    gitMinimal
    gnugrep
    patch
  ];
  ompUntrusted = writeShellApplication {
    name = "ompu";
    runtimeInputs = [ coreutils ];
    text = ''
      raw_omp=${lib.escapeShellArg (lib.getExe omp)}
      launch_cwd="$PWD"
      target_cwd="$PWD"
      original_args=( "$@" )
      forwarded_args=()

      refuse_flag() {
        printf '%s\n' \
          "ompu refused '$1': the untrusted launcher owns credentials, state, executable-resource discovery, tools, and approval policy." >&2
        exit 2
      }

      i=0
      while (( i < ''${#original_args[@]} )); do
        arg="''${original_args[$i]}"
        case "$arg" in
          --)
            forwarded_args+=( "$arg" )
            i=$((i + 1))
            while (( i < ''${#original_args[@]} )); do
              forwarded_args+=( "''${original_args[$i]}" )
              i=$((i + 1))
            done
            break
            ;;
          --cwd=*)
            target_cwd="''${arg#--cwd=}"
            ;;
          --cwd)
            (( i + 1 < ''${#original_args[@]} )) || refuse_flag "$arg"
            i=$((i + 1))
            target_cwd="''${original_args[$i]}"
            ;;
          --profile|--alias|--api-key|--config|--extension|-e|--hook|--plugin-dir|--approval-mode|--tools|--skills|--system-prompt|--append-system-prompt|--session-dir|--session|--resume|-r|--fork|--provider-session-id)
            refuse_flag "$arg"
            ;;
          --profile=*|--alias=*|--api-key=*|--config=*|--extension=*|-e=*|--hook=*|--plugin-dir=*|--approval-mode=*|--tools=*|--skills=*|--system-prompt=*|--append-system-prompt=*|--session-dir=*|--session=*|--resume=*|-r=*|--fork=*|--provider-session-id=*)
            refuse_flag "''${arg%%=*}"
            ;;
          --auto-approve|--yolo|--no-extensions)
            refuse_flag "$arg"
            ;;
          *)
            forwarded_args+=( "$arg" )
            ;;
        esac
        i=$((i + 1))
      done

      case "$target_cwd" in
        /*) ;;
        *) target_cwd="$launch_cwd/$target_cwd" ;;
      esac
      [[ -d "$target_cwd" ]] || {
        printf 'ompu target directory does not exist: %s\n' "$target_cwd" >&2
        exit 2
      }
      target_cwd="$(cd "$target_cwd" && pwd -P)"

      state_root="$HOME/.local/state/atyrode/omp-untrusted"
      if [[ -L "$state_root" ]]; then
        printf 'ompu state root must not be a symlink: %s\n' "$state_root" >&2
        exit 2
      fi
      isolated_home="$state_root/home"
      isolated_tmp="$state_root/tmp"
      isolated_worktrees="$state_root/worktrees"
      isolated_xdg_config="$state_root/xdg/config"
      isolated_xdg_data="$state_root/xdg/data"
      isolated_xdg_state="$state_root/xdg/state"
      isolated_xdg_cache="$state_root/xdg/cache"
      mkdir -p \
        "$isolated_home" \
        "$isolated_tmp" \
        "$isolated_worktrees" \
        "$isolated_xdg_config" \
        "$isolated_xdg_data" \
        "$isolated_xdg_state" \
        "$isolated_xdg_cache"
      chmod 700 "$state_root" "$isolated_home" "$isolated_tmp" "$isolated_worktrees"

      run_isolated() {
        exec env -i \
          HOME="$isolated_home" \
          USER="''${USER:-untrusted}" \
          LOGNAME="''${LOGNAME:-''${USER:-untrusted}}" \
          SHELL=${lib.escapeShellArg (lib.getExe bash)} \
          PATH=${lib.escapeShellArg trustedUntrustedPath} \
          TMPDIR="$isolated_tmp" \
          XDG_CONFIG_HOME="$isolated_xdg_config" \
          XDG_DATA_HOME="$isolated_xdg_data" \
          XDG_STATE_HOME="$isolated_xdg_state" \
          XDG_CACHE_HOME="$isolated_xdg_cache" \
          OMP_WORKTREE_DIR="$isolated_worktrees" \
          OMP_PROFILE=untrusted \
          PI_PROFILE=untrusted \
          PI_BASH_NO_LOGIN=1 \
          PI_PY=0 \
          PI_JS=0 \
          PI_RB=0 \
          PI_JL=0 \
          TERM="''${TERM:-xterm-256color}" \
          LANG=C \
          LC_ALL=C \
          SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt \
          GIT_CONFIG_NOSYSTEM=1 \
          GIT_CONFIG_GLOBAL=/dev/null \
          GIT_TERMINAL_PROMPT=0 \
          GIT_ASKPASS=${coreutils}/bin/false \
          SSH_ASKPASS=${coreutils}/bin/false \
          GIT_CONFIG_COUNT=4 \
          GIT_CONFIG_KEY_0=credential.helper \
          GIT_CONFIG_VALUE_0= \
          GIT_CONFIG_KEY_1=core.hooksPath \
          GIT_CONFIG_VALUE_1=/dev/null \
          GIT_CONFIG_KEY_2=core.fsmonitor \
          GIT_CONFIG_VALUE_2=false \
          GIT_CONFIG_KEY_3=core.sshCommand \
          GIT_CONFIG_VALUE_3=${coreutils}/bin/false \
          "$@"
      }

      case "''${forwarded_args[0]:-}" in
        __complete|agents|auth-broker|auth-gateway|bench|commit|completions|config|dry-balance|gallery|gc|grep|grievances|install|join|models|plugin|read|say|search|setup|shell|ssh|stats|tiny-models|token|ttsr|usage|worktree)
          cd ${neutralRoot}
          run_isolated "$raw_omp" --profile untrusted "''${forwarded_args[@]}"
          ;;
        update)
          printf '%s\n' 'OMP is managed by Nix. Update the pinned derivation, then run zconf.' >&2
          exit 2
          ;;
      esac

      blocked_paths=(
        "$target_cwd/.omp/extensions"
        "$target_cwd/.omp/hooks"
        "$target_cwd/.omp/plugins"
        "$target_cwd/.omp/commands"
        "$target_cwd/.omp/tools"
        "$target_cwd/.omp/package.json"
        "$target_cwd/.omp/secrets.yml"
        "$target_cwd/.pi/extensions"
        "$target_cwd/.pi/hooks"
        "$target_cwd/.pi/plugins"
        "$target_cwd/.pi/commands"
        "$target_cwd/.pi/tools"
        "$target_cwd/.claude/hooks"
        "$target_cwd/.claude/commands"
        "$target_cwd/.codex/hooks"
        "$target_cwd/.codex/commands"
        "$target_cwd/.gemini/hooks"
        "$target_cwd/.gemini/commands"
        "$target_cwd/.agents/hooks"
        "$target_cwd/.agents/commands"
      )
      for blocked in "''${blocked_paths[@]}"; do
        if [[ -e "$blocked" || -L "$blocked" ]]; then
          printf '%s\n' \
            "ompu refused the project because executable or policy-bearing project state exists at $blocked. Review/remove it or use a trusted launcher." >&2
          exit 2
        fi
      done

      managed_args=(
        --profile untrusted
        --extension ${platformRoot}
        --config ${defaultsConfig}
      )
      if [[ -e "$target_cwd/.omp/settings.json" ]]; then
        managed_args+=( --config "$target_cwd/.omp/settings.json" )
      fi
      if [[ -e "$target_cwd/.omp/config.yml" ]]; then
        managed_args+=( --config "$target_cwd/.omp/config.yml" )
      fi
      managed_args+=(
        --config ${untrustedConfig}
        --append-system-prompt ${lib.escapeShellArg untrustedPrompt}
        --no-lsp
        --no-pty
        --tools 'read,bash,edit,ast_grep,ast_edit,ask,glob,grep,inspect_image,checkpoint,rewind,task,job,todo,write'
        --cwd "$target_cwd"
      )

      cd ${neutralRoot}
      run_isolated "$raw_omp" "''${managed_args[@]}" "''${forwarded_args[@]}"
    '';
  };

  # `code` — the umbrella picker. Lists the launcher palette, resolves a
  # selector (number, name, alias, or single suffix letter) and execs the
  # matching launcher, forwarding every remaining argument. If the first
  # argument is not a known profile it opens the picker and then forwards all
  # arguments to the choice, so `code --resume` picks first, then resumes.
  codeLauncher = writeShellApplication {
    name = "code";
    runtimeInputs = [
      jq
      coreutils
      fzf
      gawk
    ];
    text = ''
      omp_bin=${lib.escapeShellArg (lib.getExe omp)}
      routes_plain=${routesHelp}/share/omp/routes.plain
      generated_plain=${generatedProfiles}/share/omp/generated.plain
      names=( ${lib.escapeShellArgs (map (p: p.cmd) paletteProfiles)} )
      leads=( ${lib.escapeShellArgs (map (p: p.lead) paletteProfiles)} )
      blurbs=( ${lib.escapeShellArgs (map (p: p.blurb) paletteProfiles)} )
      details=( ${lib.escapeShellArgs (map (p: p.detail) paletteProfiles)} )
      exes=( ${lib.escapeShellArgs (map (p: p.exe) paletteProfiles)} )
      groups=( ${lib.escapeShellArgs (map (p: p.group) paletteProfiles)} )
      count=''${#names[@]}
      show_usage_panel=1

      # Nerd Font glyphs by precise codepoint (FontAwesome range, in every Nerd
      # Font) and 24-bit truecolor accents, used by the fzf picker.
      esc=$(printf '\033')
      g_cogs=$(printf '')    # cogs — regular / routine work
      g_unlink=$(printf '')  # broken link — pure-pool, never crosses
      g_pin=$(printf '')     # thumbtack — deterministic (ompf)
      g_book=$(printf '')    # book — huge context (ompx)
      g_reset=$(printf '')  # refresh (time until reset)
      g_mixed=$(printf '')  # random / shuffle (mixed pool)
      g_openai=$(printf '')     # bolt
      g_claude=$(printf '')     # lightbulb
      g_yours=$(printf '')      # user
      g_untrusted=$(printf '')  # lock
      g_point=$(printf '')      # chevron-right
      g_search=$(printf '')     # search
      c_openai="''${esc}[38;2;98;167;255m"
      c_claude="''${esc}[38;2;255;159;82m"
      c_yours="''${esc}[38;2;120;200;170m"
      c_untrusted="''${esc}[38;2;208;92;96m"    # clear red (warning) — not the claude orange
      c_mixed="''${esc}[38;2;170;150;225m"
      c_special="''${esc}[38;2;70;190;200m"      # teal — special-purpose group
      c_dim="''${esc}[38;2;120;130;145m"
      c_ok="''${esc}[38;2;80;200;120m"
      c_warn="''${esc}[38;2;235;120;90m"
      c_near="''${esc}[38;2;235;238;242m"
      c_bold="''${esc}[1m"
      c_rst="''${esc}[0m"
      c_gpt_soft="''${esc}[38;2;110;145;190m"     # muted, grayed blue for flavour text
      c_claude_soft="''${esc}[38;2;195;160;120m"  # muted, grayed orange for flavour text

      lead_tag() {
        case "$1" in
          openai) printf '[openai]' ;;
          claude) printf '[claude]' ;;
          yours) printf '[yours]' ;;
          untrusted) printf '[untrusted]' ;;
          *) printf '[%s]' "$1" ;;
        esac
      }

      group_label() {
        case "$1" in
          mix) printf 'mixed' ;;
          gpt) printf 'gpt-led' ;;
          claude) printf 'claude-led' ;;
          special) printf 'special' ;;
          *) printf '%s' "$1" ;;
        esac
      }

      # Fill the `palette` array with one plain-ASCII line per launcher, split
      # into soft groups with a header before each.
      palette=()
      build_palette() {
        palette=( "OMP launchers" "" )
        local i last_group=""
        for (( i = 0; i < count; i++ )); do
          if [[ "''${groups[$i]}" != "$last_group" ]]; then
            [[ -n "$last_group" ]] && palette+=( "" )
            palette+=( "  $(group_label "''${groups[$i]}")" )
            last_group="''${groups[$i]}"
          fi
          palette+=( "$(printf '  %d) %-5s %-11s %s' \
            "$(( i + 1 ))" "''${names[$i]}" "$(lead_tag "''${leads[$i]}")" "''${blurbs[$i]}")" )
        done
      }

      # Render the usage rows (provider TAB label TAB pct TAB tier TAB secs TAB
      # windowSecs) into the coloured panel in a single gawk pass — a provider
      # header, then each window's gradient bar, percent used, and time to reset.
      # "Near reset" is relative to the window length (bold within the last tenth,
      # bright within the last quarter) so a barely-used 5h window resetting in
      # ~4h no longer reads as urgent.
      render_usage_panel() {
        gawk -F'\t' \
          -v c_openai="$c_openai" -v c_claude="$c_claude" -v c_dim="$c_dim" \
          -v c_bold="$c_bold" -v c_rst="$c_rst" -v c_near="$c_near" \
          -v c_ok="$c_ok" -v c_warn="$c_warn" -v esc="$esc" -v greset="$g_reset" '
          function shortwin(l) {
            if (l == "5 hours" || l == "Claude 5 Hour") return "5h"
            if (l == "7 days" || l == "Claude 7 Day") return "7d"
            if (l == "5 hours (Spark)") return "5h spark"
            if (l == "7 days (Spark)") return "7d spark"
            if (l == "Claude 7 Day (Fable)") return "7d fable"
            return l
          }
          function barstr(p,   r, g, fill, k, o) {
            if (p <= 50) { r = 90 + p * 3; g = 200 } else { r = 235; g = 200 - (p - 50) * 3 }
            if (r > 235) r = 235
            if (g < 60) g = 60
            fill = int((p * 10 + 50) / 100)
            if (fill > 10) fill = 10
            if (fill < 0) fill = 0
            o = esc "[38;2;" r ";" g ";70m"
            for (k = 0; k < fill; k++) o = o "█"
            o = o c_dim
            for (k = fill; k < 10; k++) o = o "░"
            return o c_rst
          }
          function fmtreset(s,   d, h, m) {
            if (s < 0) s = 0
            if (s >= 86400) return int(s / 86400) "d" int((s % 86400) / 3600) "h"
            if (s >= 3600) return int(s / 3600) "h" int((s % 3600) / 60) "m"
            return int(s / 60) "m"
          }
          function rstyle(s, dur) {
            if (dur > 0 && s * 10 < dur) return c_bold c_near
            if (dur > 0 && s * 4 < dur) return c_near
            return c_dim
          }
          {
            prov = $1; label = $2; pct = $3 + 0; tier = $4; rs = $5 + 0; dur = $6 + 0
            if (prov != last) {
              pcol = (prov == "openai-codex") ? c_openai : ((prov == "anthropic") ? c_claude : c_dim)
              pname = (prov == "openai-codex") ? "Codex" : ((prov == "anthropic") ? "Claude" : prov)
              print pcol c_bold pname c_rst
              last = prov
            }
            note = ""
            if (pct >= 80) note = "  " c_warn "tight" c_rst
            if (tier == "spark" && pct == 0) note = "  " c_ok "idle" c_rst
            printf "  %-8s %s %3d%% used  %s%s %s%s%s\n", shortwin(label), barstr(pct), pct, rstyle(rs, dur), greset, fmtreset(rs), c_rst, note
          }
        '
      }

      # Per-provider quota panel, filled without blocking the picker. Source
      # preference: (1) the tyrode.dev collector snapshot when present and recent
      # — refreshed continuously, so instant and always fresh; (2) a local cache
      # of `omp usage --json`, repopulated in the background so the next open is
      # warm; (3) a "fetching…" note while the first background fetch lands.
      usage_snapshot="''${TYRODE_MODEL_USAGE_SNAPSHOT:-/opt/tyrode/runtime/model-usage/snapshot.json}"
      usage_cache="''${XDG_CACHE_HOME:-$HOME/.cache}/atyrode/code-usage.json"

      # Seconds since a file's mtime, or non-zero when it is missing.
      file_age() {
        local m now
        m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
        [[ -n "$m" ]] || return 1
        now="$(date +%s)"
        printf '%d' "$(( now - m ))"
      }

      # Both sources normalise to provider<TAB>label<TAB>pct<TAB>tier<TAB>secs<TAB>
      # windowSecs, sorted so a provider's regular buckets come before its
      # separate-quota ones (Spark after Codex, Fable after Claude).
      usage_rows_from_omp() {
        jq -r '
            .reports[] | .provider as $p
            | .limits
            | sort_by((if (.scope.tier // "-") == "-" then 0 else 1 end), .window.durationMs)[]
            | $p + "\t" + .label + "\t"
              + ((.amount.usedFraction * 100) | round | tostring) + "\t"
              + (.scope.tier // "-") + "\t"
              + (((.window.resetsAt / 1000) - now) | floor | tostring) + "\t"
              + ((.window.durationMs / 1000) | floor | tostring)
          ' 2>/dev/null
      }
      usage_rows_from_snapshot() {
        jq -r '
            .providers | to_entries[]
            | (if .key == "openai" then "openai-codex" else .key end) as $p
            | (.value.lastGood.limits // [])
            | sort_by((if (.id | test("spark|fable")) then 1 else 0 end), .durationMs)[]
            | (.id | test("spark")) as $spark
            | (.id | test("fable")) as $fable
            | (.durationMs == 18000000) as $h5
            | $p + "\t"
              + (if $p == "openai-codex"
                   then (if $spark then (if $h5 then "5 hours (Spark)" else "7 days (Spark)" end)
                                   else (if $h5 then "5 hours" else "7 days" end) end)
                   else (if $fable then "Claude 7 Day (Fable)"
                                   else (if $h5 then "Claude 5 Hour" else "Claude 7 Day" end) end)
                 end) + "\t"
              + ((.usedFraction * 100) | round | tostring) + "\t"
              + (if $spark then "spark" elif $fable then "fable" else "-" end) + "\t"
              + (((.resetsAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - now) | floor | tostring) + "\t"
              + ((.durationMs / 1000) | floor | tostring)
          ' 2>/dev/null
      }
      # Detached refresh of the local cache — only reached when no fresh snapshot.
      refresh_usage_cache() {
        mkdir -p "$(dirname "$usage_cache")" 2>/dev/null || return 0
        {
          tmp="$(mktemp "$usage_cache.XXXXXX" 2>/dev/null)" || exit 0
          if timeout 8 "$omp_bin" usage --json > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
            mv -f "$tmp" "$usage_cache" 2>/dev/null
          else
            rm -f "$tmp" 2>/dev/null
          fi
        } &
      }

      # The bare `omp` runs the user's unmanaged ~/.omp. Resolve its role→model map
      # (`omp config list` is ~0.9s) into a routes.plain lead block, refreshed in the
      # background and cached, so the preview shows the *real* routing — the same as
      # the managed profiles — without ever blocking the picker.
      omp_routes_cache="''${XDG_CACHE_HOME:-$HOME/.cache}/atyrode/code-omp-routes"
      refresh_omp_routes() {
        mkdir -p "$(dirname "$omp_routes_cache")" 2>/dev/null || return 0
        {
          tmp="$(mktemp "$omp_routes_cache.XXXXXX" 2>/dev/null)" || exit 0
          if timeout 8 "$omp_bin" config get modelRoles --json 2>/dev/null \
            | jq -r '
                (.value // .) as $r
                | ["default","task","plan","slow","designer","reviewer","librarian","sonic","advisor","smol","tiny","commit"] as $ord
                | ([$ord[] | select($r[.])] + (($r | keys) - $ord))
                | .[] | "\(.)\t\($r[.])"' 2>/dev/null \
            | awk -F'\t' '{ m = $2; sub(/^[a-z-]+\//, "", m);
                mark = ($1 ~ /^(designer|librarian|reviewer|scout|sonic|task)$/) ? "  ● " : "    ";
                printf "%s%-10s %s\n", mark, $1, m }' > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
            mv -f "$tmp" "$omp_routes_cache" 2>/dev/null
          else
            rm -f "$tmp" 2>/dev/null
          fi
        } &
      }

      # Per-provider quota panel: a coloured provider header, then each window's
      # bar, percent used, and time until reset. No redundant "usage" label.
      usagep=()
      build_usage() {
        usagep=()
        (( show_usage_panel == 1 )) || return 0
        local rows="" fetching=0 age
        if [[ -r "$usage_snapshot" ]] && age="$(file_age "$usage_snapshot")" && (( age < 1800 )); then
          rows="$(usage_rows_from_snapshot < "$usage_snapshot")"
        fi
        if [[ -z "$rows" ]]; then
          if ! age="$(file_age "$usage_cache")" || (( age >= 120 )); then
            refresh_usage_cache
            fetching=1
          fi
          [[ -r "$usage_cache" ]] && rows="$(usage_rows_from_omp < "$usage_cache")"
        fi
        if [[ -z "$rows" ]]; then
          (( fetching )) && usagep+=( "''${c_dim}fetching usage…''${c_rst}" )
          return 0
        fi
        usage_rows_cache="$rows"
        mapfile -t usagep < <(render_usage_panel <<< "$rows")
      }

      # ── Provider availability ────────────────────────────────────────────────
      # Derived from the same usage rows that fill the panel. A provider is
      # `unauthed` when it never appears (omp usage only reports authed accounts),
      # `maxed` when its main (non-tier) window is >=100% used, else `ok`. With no
      # usage data at all nothing is known, so nothing is dimmed.
      # Quota buckets: name:provider:usage-tier. Fable and Spark draw SEPARATE
      # quota from their provider's main bucket, so availability is tracked per
      # bucket — a maxed Fable window takes down the Fable-led profiles even while
      # the main Claude bucket sits at 65%.
      bucket_defs=(codex-main:openai-codex:- codex-spark:openai-codex:spark claude-main:anthropic:- claude-fable:anthropic:fable)
      bucket_avail=""
      build_bucket_avail() {
        bucket_avail=""
        local rows="$usage_rows_cache" def name rest prov tier
        if [[ -z "$rows" ]]; then
          for def in "''${bucket_defs[@]}"; do bucket_avail+="''${def%%:*}=ok:0"$'\n'; done
          return 0
        fi
        for def in "''${bucket_defs[@]}"; do
          name="''${def%%:*}"; rest="''${def#*:}"; prov="''${rest%%:*}"; tier="''${rest##*:}"
          # Provider entirely absent from usage => unauthed (all its buckets).
          if ! grep -q "^$prov"$'\t' <<< "$rows"; then
            bucket_avail+="$name=unauthed:0"$'\n'
            continue
          fi
          local maxpct=-1 secs=0 pr pct t s
          while IFS=$'\t' read -r pr _ pct t s _; do
            [[ "$pr" == "$prov" && "$t" == "$tier" ]] || continue
            if (( pct > maxpct )); then maxpct=$pct; secs=$s; fi
          done <<< "$rows"
          # maxpct < 0 means the bucket window never appeared (idle/unreported) —
          # treat as available rather than dimming on missing data.
          if (( maxpct >= 100 )); then
            bucket_avail+="$name=maxed:$secs"$'\n'
          else
            bucket_avail+="$name=ok:0"$'\n'
          fi
        done
      }
      bucket_status() {
        local l
        l="$(grep "^$1=" <<< "$bucket_avail" | head -1)"
        l="''${l#*=}"
        printf '%s' "''${l%%:*}"
      }
      bucket_reset_secs() {
        local l
        l="$(grep "^$1=" <<< "$bucket_avail" | head -1)"
        printf '%s' "''${l##*:}"
      }
      bucket_down() {
        local st
        st="$(bucket_status "$1")"
        [[ "$st" == unauthed || "$st" == maxed ]]
      }
      down_buckets_csv() {
        local def name out=""
        for def in "''${bucket_defs[@]}"; do
          name="''${def%%:*}"
          if bucket_down "$name"; then out+="$name,"; fi
        done
        printf '%s' "''${out%,}"
      }
      # Compact "5d" / "2h" / "45m" from a seconds count.
      fmt_secs() {
        local s="$1"
        if (( s <= 0 )); then printf 'now'
        elif (( s >= 86400 )); then printf '%dd' "$(( s / 86400 ))"
        elif (( s >= 3600 )); then printf '%dh' "$(( s / 3600 ))"
        elif (( s >= 60 )); then printf '%dm' "$(( s / 60 ))"
        else printf '%ds' "$s"; fi
      }
      # Human note for a down bucket: "Fable maxed · 5d" / "Codex maxed · 2h", or
      # "needs Claude" when the whole provider is unauthed.
      bucket_note() {
        local b="$1" label st
        case "$b" in
          codex-main) label="Codex" ;; codex-spark) label="Spark" ;;
          claude-main) label="Claude" ;; claude-fable) label="Fable" ;; *) label="$b" ;;
        esac
        st="$(bucket_status "$b")"
        case "$st" in
          maxed) printf '%s maxed · %s' "$label" "$(fmt_secs "$(bucket_reset_secs "$b")")" ;;
          unauthed)
            case "$b" in
              codex-*) printf 'needs Codex' ;;
              claude-*) printf 'needs Claude' ;;
              *) printf 'needs %s' "$label" ;;
            esac ;;
          *) printf '%s' "" ;;
        esac
      }

      # ── Per-profile impact ───────────────────────────────────────────────────
      # name<TAB>impact (ok|degraded|broken), judged on each profile's substantive
      # lead roles in the routes page against the currently-down providers.
      profile_impacts=""
      build_profile_impacts() {
        profile_impacts=""
        [[ -f "$routes_plain" ]] || return 0
        local down
        down="$(down_buckets_csv)"
        profile_impacts="$(awk -v down="$down" '
          BEGIN {
            split(down, d, ","); for (i in d) if (d[i] != "") dmap[d[i]] = 1
            split("default task plan slow designer reviewer librarian", s, " ")
            for (i in s) smap[s[i]] = 1
          }
          function bucket(m) {
            sub(/:.*/, "", m)
            if (m ~ /fable/) return "claude-fable"
            if (m ~ /spark/) return "codex-spark"
            if (m ~ /claude|sonnet|haiku|opus/) return "claude-main"
            return "codex-main"
          }
          function ismodel(t) { return t ~ /^[A-Za-z0-9.-]+:(minimal|low|medium|high|xhigh|max)$/ }
          function emit(   im) {
            if (name == "") return
            # broken: the interactive default cannot run — its lead and every
            # displayed fallback bucket is down (a no-fallback profile has only
            # its lead). degraded: default runs, but a substantive lead is down.
            im = (default_seen && !default_runnable) ? "broken" : (any_lead_down ? "degraded" : "ok")
            printf "%s\t%s\n", name, im
          }
          /^[a-z][a-z0-9-]*  / { emit(); name = $1; any_lead_down = 0; default_seen = 0; default_runnable = 0; next }
          {
            role = ""; lead = ""
            for (i = 1; i <= NF; i++) {
              if ($i == "●") continue
              if (role == "" && $i ~ /^[a-z]+$/) { role = $i; continue }
              if (ismodel($i)) {
                if (lead == "") lead = $i
                if (role == "default") { default_seen = 1; if (!(bucket($i) in dmap)) default_runnable = 1 }
              }
            }
            if (role in smap && lead != "" && (bucket(lead) in dmap)) any_lead_down = 1
          }
          END { emit() }
        ' "$routes_plain")"
      }
      profile_impact() {
        awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' <<< "$profile_impacts"
      }
      # Compute availability once per process. The preview runs as its own process
      # (see __preview), so it recomputes; cheap — reads the cached usage rows.
      avail_built=0
      ensure_avail() {
        (( avail_built )) && return 0
        build_usage
        build_bucket_avail
        build_profile_impacts
        avail_built=1
      }
      # Annotation for impacted profiles: the note(s) of the currently-down
      # bucket(s), de-duplicated (an unauthed provider downs two buckets that
      # share one "needs X" note). Usually one bucket is down, so this is short.
      down_annotation() {
        local def name n out="" seen=""
        for def in "''${bucket_defs[@]}"; do
          name="''${def%%:*}"
          if bucket_down "$name"; then
            n="$(bucket_note "$name")"
            [[ -n "$n" ]] || continue
            case "$seen" in *"|$n|"*) continue ;; esac
            seen+="|$n|"
            out+="''${out:+ · }$n"
          fi
        done
        printf '%s' "$out"
      }

      term_cols() {
        local rows cols
        if read -r rows cols < <(stty size 2>/dev/null) && [[ -n "''${cols:-}" ]]; then
          printf '%s' "$cols"
        else
          printf '%s' "''${COLUMNS:-80}"
        fi
      }

      # Print the palette, with the usage panel beside it when the terminal is
      # wide enough, otherwise stacked above it.
      render_screen() {
        build_palette
        build_usage
        if (( ''${#usagep[@]} == 0 )); then
          printf '%s\n' "''${palette[@]}"
          return 0
        fi
        local leftw=0 line
        for line in "''${palette[@]}"; do (( ''${#line} > leftw )) && leftw=''${#line}; done
        local cols
        cols="$(term_cols)"
        if (( cols < leftw + 24 )); then
          printf '%s\n' "''${usagep[@]}" "" "''${palette[@]}"
          return 0
        fi
        local n=''${#palette[@]}
        (( ''${#usagep[@]} > n )) && n=''${#usagep[@]}
        local i l r
        for (( i = 0; i < n; i++ )); do
          l="''${palette[$i]:-}"
          r="''${usagep[$i]:-}"
          printf '%-*s  %s\n' "$leftw" "$l" "$r"
        done
      }

      show_detail() {
        local i="$1"
        printf '\n  %s  %s\n  %s\n\n' \
          "''${names[$i]}" "$(lead_tag "''${leads[$i]}")" "''${details[$i]}"
      }

      # Colour by lane (mixed/gpt/claude/special/bare) and glyph by intended use
      # (speed/regular/smart/pure-pool + per-special icons), keyed on the launcher
      # name so the icon matches what the profile is for, not just its provider.
      lane_color() {
        case "$1" in
          ompz | ompn | ompm) printf '%s' "$c_mixed" ;;
          ompl | ompb | ompg | ompo) printf '%s' "$c_openai" ;;
          ompk | omps | ompc | ompe) printf '%s' "$c_claude" ;;
          ompf | ompx) printf '%s' "$c_special" ;;
          ompu) printf '%s' "$c_untrusted" ;;
          *) printf '%s' "$c_yours" ;;
        esac
      }
      icon_glyph() {
        case "$1" in
          ompz | ompl | ompk) printf '%s' "$g_openai" ;;
          ompn | ompb | omps) printf '%s' "$g_cogs" ;;
          ompm | ompg | ompc) printf '%s' "$g_claude" ;;
          ompo | ompe) printf '%s' "$g_unlink" ;;
          ompf) printf '%s' "$g_pin" ;;
          ompx) printf '%s' "$g_book" ;;
          ompu) printf '%s' "$g_untrusted" ;;
          omp) printf '%s' "$g_yours" ;;
          *) printf '%s' "$g_mixed" ;;
        esac
      }

      # Compact + recolour a routing block for the preview. Mode selects depth:
      # "lead" keeps only the primary per role, "base" collapses same-provider
      # redundancy siblings to show just the cross-provider net, "full" keeps the
      # whole chain (the picker cycles lead -> base -> full on ctrl-f). Names
      # shorten to their tier (gpt-5.6-sol -> sol) and colour by provider hue with
      # brightness scaled by thinking level (low -> xhigh reads as dim -> bright).
      colorize_routes() {
        local mode="''${1:-base}"
        gawk -v dim="$c_dim" -v mode="$mode" '
          function lvl(l) { return l=="minimal"?0:l=="low"?1:l=="medium"?2:l=="high"?3:l=="xhigh"?4:5 }
          function clamp(x) { return x>255?255:(x<0?0:int(x)) }
          function short(name,   a, n) {
            if (name == "gpt-5.4") return "gpt-5.4"
            n = split(name, a, "-")
            if (name ~ /^claude/) return a[2]
            return a[n]
          }
          function paint(tok,   idx, name, level, f, br, bg, bb) {
            idx = match(tok, /:(minimal|low|medium|high|xhigh|max)$/)
            if (idx == 0) return tok
            name = substr(tok, 1, idx - 1); level = substr(tok, idx + 1)
            if (tok ~ /^gpt/) { br = 110; bg = 170; bb = 240 }
            else if (tok ~ /^claude/) { br = 240; bg = 160; bb = 105 }
            else return tok
            f = 0.60 + lvl(level) * 0.088
            return sprintf("\033[38;2;%d;%d;%dm%s:%s%s", clamp(br*f), clamp(bg*f), clamp(bb*f), short(name), level, dim)
          }
          function prov_of(s) {
            # Spark and Fable draw separate quota, so they are their own bucket —
            # a hop off them is a real fallback (different rate), never a
            # same-bucket redundancy sibling to collapse.
            if (s ~ /spark/) return "s"
            if (s ~ /fable/) return "f"
            return s ~ /claude/ ? "c" : (s ~ /gpt/ ? "g" : "x")
          }
          {
            line = $0
            # Drop the redundant profile header (col 0) — the preview shows the
            # name/blurb itself — and the profile-level thinking/fallback/advisor
            # line, which is redundant with the per-role levels.
            if (line ~ /^[a-z]/) next
            if (line ~ /thinking .* fallback/) next
            # Split off any trailing task override so it never confuses the
            # provider walk, then re-append it before painting.
            ov = ""
            if (match(line, / +\(task override:/)) {
              ov = substr(line, RSTART); line = substr(line, 1, RSTART - 1)
            }
            # Normalise the padded arrow gaps to a single space either side.
            gsub(/ +→ +/, " → ", line)
            if (mode == "lead") {
              # Primary only — drop the whole chain.
              sub(/ +→.*$/, "", line)
            } else if (mode == "base") {
              # Collapse consecutive same-bucket models (the redundancy siblings)
              # so only the lead and each bucket transition remain — Spark and
              # Fable are their own bucket, so a hop off them is always kept.
              n = split(line, parts, / +→ +/)
              line = parts[1]
              lastprov = prov_of(parts[1])
              for (j = 2; j <= n; j++) {
                if (prov_of(parts[j]) != lastprov) {
                  line = line " → " parts[j]; lastprov = prov_of(parts[j])
                }
              }
            }
            line = line ov
            out = ""
            # paint() calls match() internally, which clobbers RSTART/RLENGTH, so
            # snapshot them before each call.
            while (match(line, /(gpt|claude)[A-Za-z0-9._-]*:(minimal|low|medium|high|xhigh|max)/)) {
              s = RSTART; l = RLENGTH
              out = out substr(line, 1, s - 1) paint(substr(line, s, l))
              line = substr(line, s + l)
            }
            print out line
          }
        '
      }

      # Colour provider/model mentions in flavour text with a muted, grayed
      # version of the provider hue, restoring to the surrounding dim gray.
      flavorize() {
        gawk -v g="$c_gpt_soft" -v c="$c_claude_soft" -v dim="$c_dim" '
          {
            line = $0
            gsub(/\<(GPT|gpt|OpenAI|Codex|Spark|spark|Sol|Terra|Luna|Nano|nano)\>/, g "&" dim, line)
            gsub(/\<(Claude|claude|Anthropic|Opus|opus|Sonnet|sonnet|Haiku|haiku|Fable|fable)\>/, c "&" dim, line)
            print line
          }
        '
      }

      # Arrow-key picker via fzf: a truecolor list with Nerd Font provider
      # glyphs and soft group labels at the top, the usage panel in the footer,
      # and each profile's detail + colourised role -> model routing in the
      # preview. Sets picked_idx, or leaves it empty when cancelled.
      # Render profile <name> at depth <state> (0/1/2) to stdout. Shared by the
      # on-demand fzf preview and the background preloader, so startup pre-renders
      # nothing and navigation is still instant once the cache is warm.
      # Bundled OMP subagents shown in the preview for the profiles with no managed
      # routing to display (bare omp, ompu). Built once from the pinned agents dir.
      agents_block=""
      build_agents_block() {
        [[ -n "$agents_block" ]] && return 0
        local f n d line
        for f in ${omp-agents}/share/omp/agents/*.md; do
          [[ -e "$f" ]] || continue
          n="''${f##*/}"; n="''${n%.md}"
          case "$n" in
            designer)  d="UI/UX design & visual refinement" ;;
            librarian) d="reads external libraries & APIs" ;;
            reviewer)  d="code quality & security review" ;;
            scout)     d="fast codebase exploration" ;;
            sonic)     d="mechanical, low-reasoning edits" ;;
            task)      d="general multi-step delegation" ;;
            *)         d="" ;;
          esac
          printf -v line '  %s●%s %s%-10s%s %s%s%s' \
            "$c_dim" "$c_rst" "$c_bold" "$n" "$c_rst" "$c_dim" "$d" "$c_rst"
          agents_block+="$line"$'\n'
        done
        agents_block="''${agents_block%$'\n'}"
      }

      render_one() {
        local profile="$1" s="$2" i idx=-1 col gly fdetail block why
        for (( i = 0; i < count; i++ )); do
          [[ "''${names[$i]}" == "$profile" ]] && { idx=$i; break; }
        done
        (( idx >= 0 )) || return 0
        ensure_avail
        col="$(lane_color "''${names[$idx]}")"
        gly="$(icon_glyph "''${names[$idx]}")"
        fdetail="$(printf '%s' "''${details[$idx]}" | flavorize)"
        printf '%s%s %s%s%s\n' "$col" "$gly" "$c_bold" "''${names[$idx]}" "$c_rst"
        printf '%s%s%s\n\n' "$col" "''${blurbs[$idx]}" "$c_rst"
        printf '%s%s%s\n' "$c_dim" "$fdetail" "$c_rst"
        # the bare omp has no managed routing — show the user's own resolved ~/.omp
        # routing (cached, refreshed in the background), or its bundled subagents until
        # the first resolve lands. ompu falls through: its routing is in routes.plain.
        case "''${names[$idx]}" in
          omp)
            local orblock=""
            [[ -r "$omp_routes_cache" ]] && orblock="$(colorize_routes lead < "$omp_routes_cache")"
            if [[ -n "$orblock" ]]; then
              printf '\n%s── routing · your ~/.omp ────%s\n%s%s%s\n' "$c_dim" "$c_rst" "$c_dim" "$orblock" "$c_rst"
            else
              build_agents_block
              printf '\n%s── agents ──────────────────%s\n%s\n' "$c_dim" "$c_rst" "$agents_block"
            fi
            return 0
            ;;
        esac
        # Availability banner: flag the focused launcher when a quota bucket its
        # routing leads on is down. Broken = its default has no live fallback
        # (unusable until reset); degraded = it runs, on a fallback model.
        local pimpact; pimpact="$(profile_impact "$profile")"
        if [[ "$pimpact" == broken ]]; then
          printf '\n%s✗ %s — default has no live fallback%s\n' "$c_untrusted" "$(down_annotation)" "$c_rst"
        elif [[ "$pimpact" == degraded ]]; then
          printf '\n%s⚠ %s — runs on a fallback model%s\n' "$c_claude" "$(down_annotation)" "$c_rst"
        fi
        [[ -f "$routes_plain" ]] || return 0
        # Behaviour summary (thinking baseline / fallback / advisor), lifted from
        # the 2nd line of the profile's block in the generated routes page so it
        # cannot drift from the deployed config.
        local cfg
        cfg="$(sed -n "/^''${names[$idx]}  /,/^\$/p" "$routes_plain" | sed -n '2s/^  *//p')"
        [[ -n "$cfg" ]] && printf '\n%s%s%s\n' "$c_dim" "$cfg" "$c_rst"
        case "$s" in
          0)
            block="$(sed -n "/^''${names[$idx]}  /,/^\$/p" "$routes_plain" | colorize_routes lead)"
            [[ -n "$block" ]] || return 0
            printf '\n%s── routing ─────────────────%s\n%s%s%s\n' "$c_dim" "$c_rst" "$c_dim" "$block" "$c_rst"
            printf '\n%sctrl-f · show fallback route · shift↑↓ scroll%s\n' "$c_dim" "$c_rst"
            ;;
          2)
            block="$(sed -n "/^''${names[$idx]}  /,/^\$/p" "$routes_plain" | colorize_routes full)"
            [[ -n "$block" ]] || return 0
            why="$(printf '%s' 'why the extra hops: each lead keeps a same-provider backup before it crosses providers, so a single-model outage or fault is absorbed in its own bucket first (gpt→gpt→claude→claude). Spark and Fable draw separate quota, so they sit out.' | flavorize)"
            printf '\n%s── routing + redundancy ────%s\n%s%s%s\n' "$c_dim" "$c_rst" "$c_dim" "$block" "$c_rst"
            printf '\n%s%s%s\n' "$c_dim" "$why" "$c_rst"
            printf '\n%sctrl-f · hide fallbacks · shift↑↓ scroll%s\n' "$c_dim" "$c_rst"
            ;;
          *)
            block="$(sed -n "/^''${names[$idx]}  /,/^\$/p" "$routes_plain" | colorize_routes base)"
            [[ -n "$block" ]] || return 0
            printf '\n%s── routing + fallback ──────%s\n%s%s%s\n' "$c_dim" "$c_rst" "$c_dim" "$block" "$c_rst"
            printf '\n%sctrl-f · show sibling redundancy · shift↑↓ scroll%s\n' "$c_dim" "$c_rst"
            ;;
        esac
      }
      # On-demand preview for fzf: render at the current depth from the state file.
      render_preview() {
        render_one "$2" "$(cat "$1/.state" 2>/dev/null || echo 0)"
      }
      # Warm every profile × depth into the cache (run in the background on start).
      render_all() {
        local prevdir="$1" i st
        for (( i = 0; i < count; i++ )); do
          for st in 0 1 2; do
            render_one "''${names[$i]}" "$st" > "$prevdir/''${names[$i]}.s$st.part" 2>/dev/null \
              && mv -f "$prevdir/''${names[$i]}.s$st.part" "$prevdir/''${names[$i]}.s$st" 2>/dev/null
          done
        done
      }

      # Full-screen "starting" card held across omp's cold start (see the launch
      # path): the profile, its description, and its lead-only routing, so the
      # hand-off amplifies the picker instead of dropping to a bare terminal.
      starting_card() {
        local idx="$1" rows="" cols="" col gly block nlines top margin width r line
        read -r rows cols < <(stty size 2>/dev/null) || true
        [[ "$rows" =~ ^[0-9]+$ ]] && (( rows >= 8 )) || rows=24
        [[ "$cols" =~ ^[0-9]+$ ]] && (( cols >= 24 )) || cols=80
        col="$(lane_color "''${names[$idx]}")"
        gly="$(icon_glyph "''${names[$idx]}")"
        margin=$(( (cols - 56) / 2 )); (( margin < 2 )) && margin=2
        width=$(( cols - margin - 2 )); (( width < 20 )) && width=20
        local -a dlines=() rlines=()
        mapfile -t dlines < <(printf '%s' "''${details[$idx]}" | fold -s -w "$width" | flavorize)
        block=""
        [[ -f "$routes_plain" ]] && block="$(sed -n "/^''${names[$idx]}  /,/^\$/p" "$routes_plain" | colorize_routes lead)"
        [[ -n "$block" ]] && mapfile -t rlines <<< "$block"
        nlines=$(( 3 + ''${#dlines[@]} + ''${#rlines[@]} ))
        top=$(( (rows - nlines) / 2 )); (( top < 1 )) && top=1
        printf '\e[2J\e[H\e[?25l'
        printf '\e[%d;%dH%s%s %s%s%s  %s⟳ starting…%s' "$top" "$margin" \
          "$col" "$gly" "$c_bold" "''${names[$idx]}" "$c_rst" "$c_dim" "$c_rst"
        r=$(( top + 2 ))
        for line in "''${dlines[@]}"; do
          printf '\e[%d;%dH%s%s%s' "$r" "$margin" "$c_dim" "$line" "$c_rst"; r=$(( r + 1 ))
        done
        r=$(( r + 1 ))
        for line in "''${rlines[@]}"; do
          printf '\e[%d;%dH%s%s%s' "$r" "$margin" "$c_dim" "$line" "$c_rst"; r=$(( r + 1 ))
        done
      }

      # Optional startup profiler: CODE_PROFILE=1 prints section timestamps.
      _prof() { [[ -z "''${CODE_PROFILE:-}" ]] || printf 'PROF %-10s %s\n' "$1" "$EPOCHREALTIME" >&2; }
      picked_idx=""
      fzf_pick() {
        picked_idx=""
        _prof entry
        build_usage
        build_bucket_avail
        build_profile_impacts
        # Kick a background refresh of the bare-omp routing cache when stale (~0.9s;
        # never blocks — the omp preview reads whatever is cached, agents until then).
        local rt_age=""
        if ! rt_age="$(file_age "$omp_routes_cache")" || (( rt_age >= 3600 )); then
          refresh_omp_routes
        fi
        _prof usage
        local footer=""
        local -a footer_args=()
        if (( ''${#usagep[@]} > 0 )); then
          printf -v footer '%s\n' "''${usagep[@]}"
          footer="''${footer%$'\n'}"
          footer_args=( --footer="$footer" --footer-border=top )
        fi
        local prevdir self
        prevdir="$(mktemp -d)"
        self="$(command -v -- "$0" 2>/dev/null)" || self="$0"
        # Previews cache under $prevdir as <name>.s<depth>. fzf calls `show`, which
        # cats the cached file when ready or renders on demand via `code __preview`;
        # a background `code __preload` (kicked on fzf start) warms them all so
        # navigation is instant. `cycle` bumps the depth (0 hidden · 1 net · 2 full).
        # shellcheck disable=SC2016
        printf '%s\n' \
          '#!/bin/sh' \
          "self=$self" \
          'd=''${0%/*}' \
          's=$(cat "$d/.state" 2>/dev/null || echo 0)' \
          'f="$d/$1.s$s"' \
          '[ -f "$f" ] && cat "$f" || "$self" __preview "$d" "$1"' > "$prevdir/show"
        # shellcheck disable=SC2016
        printf '%s\n' \
          '#!/bin/sh' \
          'd=''${0%/*}' \
          's=$(cat "$d/.state" 2>/dev/null || echo 0)' \
          'echo "$(( (s + 1) % 3 ))" > "$d/.state"' > "$prevdir/cycle"
        chmod +x "$prevdir/show" "$prevdir/cycle"
        local i col gly rows="" row glabel labelcol last_group=""
        # Flavour-tint the blurbs (openai/claude/model mentions) in one gawk pass
        # so the hot loop stays subshell-free.
        local -a fblurbs=()
        mapfile -t fblurbs < <(printf '%s\n' "''${blurbs[@]}" | flavorize)
        # Colour by lane, glyph by intended use, both inlined; the category label
        # is printed once on each group's first row.
        for (( i = 0; i < count; i++ )); do
          case "''${names[$i]}" in
            ompz | ompn | ompm) col="$c_mixed" ;;
            ompl | ompb | ompg | ompo) col="$c_openai" ;;
            ompk | omps | ompc | ompe) col="$c_claude" ;;
            ompf | ompx) col="$c_special" ;;
            ompu) col="$c_untrusted" ;;
            *) col="$c_yours" ;;
          esac
          case "''${names[$i]}" in
            ompz | ompl | ompk) gly="$g_openai" ;;
            ompn | ompb | omps) gly="$g_cogs" ;;
            ompm | ompg | ompc) gly="$g_claude" ;;
            ompo | ompe) gly="$g_unlink" ;;
            ompf) gly="$g_pin" ;;
            ompx) gly="$g_book" ;;
            ompu) gly="$g_untrusted" ;;
            omp) gly="$g_yours" ;;
            *) gly="$g_mixed" ;;
          esac
          glabel=""
          if [[ "''${groups[$i]}" != "$last_group" ]]; then
            glabel="$(group_label "''${groups[$i]}")"
            last_group="''${groups[$i]}"
          fi
          # Provider availability: mark a profile whose interactive default can't
          # run (broken → red ✗, also dimmed) or that a down bucket merely touches
          # (degraded → amber ⚠). The full reason lives in the preview banner.
          local namestyle="$c_bold" mark=" " impact=""
          impact="$(profile_impact "''${names[$i]}")"
          case "$impact" in
            broken)   mark="''${c_untrusted}✗''${c_rst}"; col="$c_dim"; namestyle="$c_dim" ;;
            degraded) mark="''${c_claude}⚠''${c_rst}" ;;
          esac
          printf -v labelcol '%-10s' "$glabel"
          printf -v row '%s\t%s%s%s  %s%s%s  %s%-5s%s %s  %s%s%s' \
            "''${names[$i]}" \
            "$c_dim" "$labelcol" "$c_rst" \
            "$col" "$gly" "$c_rst" \
            "$namestyle" "''${names[$i]}" "$c_rst" \
            "$mark" \
            "$c_dim" "''${fblurbs[$i]}" "$c_rst"
          rows+="$row"$'\n'
        done
        _prof rows
        local theme chosen cmd
        theme='fg:-1,bg:-1,fg+:#ffffff,bg+:#1b212b,hl:#62a7ff,hl+:#8ec7ff'
        theme+=',pointer:#ff9f52,marker:#ff9f52,prompt:#ff9f52,spinner:#ff9f52'
        theme+=',border:#3a4453,label:#9aa4b1,info:#69727e'
        theme+=',footer:#9aa4b1,footer-border:#3a4453'
        theme+=',gutter:-1,preview-border:#3a4453'
        _prof fzf
        chosen="$(printf '%s' "$rows" | fzf \
          --ansi --layout=reverse --height=99% --border=rounded \
          --border-label=" pick a launcher " \
          --prompt="$g_search  " --pointer="$g_point" --marker='+' --info=inline --no-mouse \
          --delimiter=$'\t' --with-nth=2 \
          --preview="$prevdir/show {1}" \
          --preview-window='right:52%:wrap:border-left' \
          --bind="start:execute-silent($self __preload $prevdir &)" \
          --bind="ctrl-f:execute-silent($prevdir/cycle)+refresh-preview" \
          --bind="shift-up:preview-up,shift-down:preview-down" \
          --bind="alt-up:preview-half-page-up,alt-down:preview-half-page-down" \
          "''${footer_args[@]}" \
          --color="$theme" || true)"
        rm -rf "$prevdir"
        cmd="''${chosen%%$'\t'*}"
        [[ -n "$cmd" ]] || return 0
        for (( i = 0; i < count; i++ )); do
          [[ "''${names[$i]}" == "$cmd" ]] && { picked_idx="$i"; return 0; }
        done
      }

      # Print a 0-based index for a selector, or return non-zero when unmatched.
      resolve() {
        local sel="$1" i n
        case "$sel" in
          plain | bare) sel=omp ;;
        esac
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
          if (( sel >= 1 && sel <= count )); then
            printf '%d' "$(( sel - 1 ))"
            return 0
          fi
          return 1
        fi
        for (( i = 0; i < count; i++ )); do
          if [[ "$sel" == "''${names[$i]}" ]]; then
            printf '%d' "$i"
            return 0
          fi
        done
        if [[ "$sel" =~ ^[a-z]$ ]]; then
          for (( i = 0; i < count; i++ )); do
            n="''${names[$i]}"
            if [[ "$n" == omp? && "''${n: -1}" == "$sel" ]]; then
              printf '%d' "$i"
              return 0
            fi
          done
        fi
        return 1
      }

      usage() {
        printf '%s\n' \
          'code - pick an OMP launcher and run it' \
          "" \
          'usage:' \
          '  code                    open the picker (with a live usage panel)' \
          '  code <profile>          run that launcher (name, number, or letter)' \
          '  code <profile> [args]   run it, forwarding all extra args' \
          '  code -l, --list         print the palette and exit' \
          '  code -U, --no-usage     open the picker without fetching usage' \
          '  code -h, --help         this help' \
          "" \
          'Profiles: omp (bare) - ompb omps ompg ompc ompf ompx - ompu (untrusted).' \
          'A first argument that is not a profile opens the picker, then forwards all' \
          'args to your choice, so code --resume picks, then resumes.' \
          'The picker shows a live omp-usage panel beside the options (best-effort);' \
          'for the full role/model routing of each managed profile, run omph.'
      }

      # ── Generator view (code gen) ────────────────────────────────────────────
      # Build a profile by browsing facets. Each facet is a file under a temp dir;
      # ←/→ cycles the focused facet, and the preview renders the baked profile
      # for the current combination (generated.plain, keyed by combo id).
      facet_order=(lane model thinking spark fable)
      facet_values() {
        case "$1" in
          lane) printf 'gpt-only gpt-led mixed claude-led claude-only' ;;
          model) printf 'fast normal smart' ;;
          thinking) printf 'low medium high xhigh' ;;
          spark | fable) printf 'on off' ;;
        esac
      }
      # Base colour for an option — lane by provider, on-toggles green, else none.
      facet_opt_color() {
        case "$1:$2" in
          lane:gpt-only | lane:gpt-led) printf '%s' "$c_openai" ;;
          lane:mixed) printf '%s' "$c_mixed" ;;
          lane:claude-led | lane:claude-only) printf '%s' "$c_claude" ;;
          spark:on | fable:on) printf '%s' "$c_yours" ;;
          *) printf '%s' "" ;;
        esac
      }
      # A Nerd Font icon per facet to anchor the eye.
      facet_icon() {
        case "$1" in
          lane) printf '%s' "$g_unlink" ;;
          model) printf '%s' "$g_cogs" ;;
          thinking) printf '%s' "$g_claude" ;;
          spark) printf '%s' "$g_openai" ;;
          fable) printf '%s' "$g_pin" ;;
        esac
      }
      facet_combo_id() {
        local d="$1" lane model th sp fb spid=nosp faid=nofa
        lane="$(cat "$d/lane")"; model="$(cat "$d/model")"; th="$(cat "$d/thinking")"
        sp="$(cat "$d/spark")"; fb="$(cat "$d/fable")"
        [[ "$lane" == gpt-only ]] && fb=off        # Fable is Anthropic-only
        [[ "$lane" == claude-only ]] && sp=off     # Spark is OpenAI-only
        [[ "$sp" == on ]] && spid=sp
        [[ "$fb" == on ]] && faid=fa
        printf '%s_%s_%s_%s_%s' "$lane" "$model" "$th" "$spid" "$faid"
      }
      facet_rows() {
        local d="$1" key val lane icon line o color na
        local -a opts
        lane="$(cat "$d/lane")"
        for key in "''${facet_order[@]}"; do
          val="$(cat "$d/$key" 2>/dev/null)"
          icon="$(facet_icon "$key")"
          na=""
          [[ "$key" == fable && "$lane" == gpt-only ]] && na=1
          [[ "$key" == spark && "$lane" == claude-only ]] && na=1
          read -ra opts <<< "$(facet_values "$key")"
          line=""
          for o in "''${opts[@]}"; do
            if [[ -n "$na" ]]; then
              line+="   ''${c_dim}$o''${c_rst}"                       # facet doesn't apply here
            elif [[ "$o" == "$val" ]]; then
              color="$(facet_opt_color "$key" "$o")"
              line+="  ''${c_bold}''${color}[$o]''${c_rst}"           # selected
            else
              line+="   ''${c_dim}$o''${c_rst}"                       # unselected
            fi
          done
          [[ -n "$na" ]] && line+="   ''${c_dim}— n/a for this lane''${c_rst}"
          printf '%s\t %s %s%-9s%s%s\n' "$key" "$icon" "$c_dim" "$key" "$c_rst" "$line"
        done
      }
      facet_cycle() {
        local d="$1" key="$2" dir="$3" cur i n
        local -a arr
        cur="$(cat "$d/$key" 2>/dev/null)"
        read -ra arr <<< "$(facet_values "$key")"
        n=''${#arr[@]}
        for i in "''${!arr[@]}"; do [[ "''${arr[$i]}" == "$cur" ]] && break; done
        if [[ "$dir" == fwd ]]; then i=$(( (i + 1) % n )); else i=$(( (i - 1 + n) % n )); fi
        printf '%s' "''${arr[$i]}" > "$d/$key"
      }
      facet_preview() {
        local d="$1" id block
        id="$(facet_combo_id "$d")"
        block="$(sed -n "/^$id  /,/^\$/p" "$generated_plain" | colorize_routes base)"
        printf '%sgenerated profile%s\n' "$c_bold" "$c_rst"
        printf '%s%s%s\n' "$c_dim" "$(printf '%s' "$id" | tr _ ' ')" "$c_rst"
        if [[ -n "$block" ]]; then
          printf '\n%s── routing ─────────────────%s\n%s%s%s\n' "$c_dim" "$c_rst" "$c_dim" "$block" "$c_rst"
        else
          printf '\n%sno profile for this combination%s\n' "$c_dim" "$c_rst"
        fi
        printf '\n%s←/→ pick option · ↑/↓ change facet · tab: hand-made list%s\n' "$c_dim" "$c_rst"
      }
      facet_pick() {
        local fdir self
        fdir="$(mktemp -d)"
        printf mixed > "$fdir/lane"; printf normal > "$fdir/model"; printf medium > "$fdir/thinking"
        printf on > "$fdir/spark"; printf off > "$fdir/fable"
        self="$(command -v -- "$0" 2>/dev/null)" || self="$0"
        facet_rows "$fdir" | fzf \
          --ansi --layout=reverse --height=99% --border=rounded \
          --border-label=" build a profile " \
          --delimiter=$'\t' --with-nth=2 --no-mouse --info=hidden --pointer="$g_point" \
          --preview="$self __facet_preview $fdir" \
          --preview-window='right:56%:wrap:border-left' \
          --bind="left:execute-silent($self __facet_cycle $fdir {1} back)+reload($self __facet_rows $fdir)+refresh-preview" \
          --bind="right:execute-silent($self __facet_cycle $fdir {1} fwd)+reload($self __facet_rows $fdir)+refresh-preview" \
          --bind="tab:become(CODE_NO_FZF= $self)" \
          >/dev/null 2>&1 || true
      }

      if [[ "''${1:-}" == __facet_rows ]]; then
        facet_rows "$2"
        exit 0
      fi
      if [[ "''${1:-}" == __facet_cycle ]]; then
        facet_cycle "$2" "$3" "$4"
        exit 0
      fi
      if [[ "''${1:-}" == __facet_preview ]]; then
        facet_preview "$2"
        exit 0
      fi

      if [[ "''${1:-}" == __preview ]]; then
        render_preview "$2" "$3"
        exit 0
      fi
      if [[ "''${1:-}" == __preload ]]; then
        render_all "$2"
        exit 0
      fi

      case "''${1:-}" in
        -U | --no-usage)
          show_usage_panel=0
          shift
          ;;
      esac

      idx=""
      if (( $# > 0 )); then
        case "$1" in
          -h | --help)
            usage
            exit 0
            ;;
          -l | --list)
            build_palette
            printf '%s\n' "''${palette[@]}"
            exit 0
            ;;
          gen)
            # Generator view: browse facets, preview the synthesised profile.
            if command -v fzf >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
              facet_pick
            else
              printf 'code gen needs fzf and an interactive terminal.\n' >&2
              exit 2
            fi
            exit 0
            ;;
        esac
        if idx="$(resolve "$1")"; then
          shift
          exec "''${exes[$idx]}" "$@"
        fi
      fi

      if [[ ! -t 0 || ! -t 1 ]]; then
        build_palette
        printf 'code: no profile given and no interactive terminal.\n\n' >&2
        printf '%s\n' "''${palette[@]}" >&2
        exit 2
      fi

      # Prefer the fzf arrow-key picker; fall back to the typed menu when fzf is
      # unavailable or CODE_NO_FZF is set.
      if command -v fzf >/dev/null 2>&1 && [[ -z "''${CODE_NO_FZF:-}" ]]; then
        fzf_pick
        if [[ -n "$picked_idx" ]]; then
          # Hold the starting card across omp's ~0.6s cold start (it clears + draws
          # inline once ready) so the picker never flashes back to the terminal.
          starting_card "$picked_idx"
          exec "''${exes[$picked_idx]}" "$@"
        fi
        exit 0
      fi

      render_screen
      while true; do
        printf '\npick [1-%d - name - ?N for details - q]: ' "$count"
        if ! read -r reply; then
          printf '\n'
          exit 0
        fi
        case "$reply" in
          q | quit | "")
            exit 0
            ;;
          \?*)
            sel="''${reply#\?}"
            sel="''${sel# }"
            if di="$(resolve "$sel")"; then
              show_detail "$di"
            else
              printf '  no such profile: %s\n\n' "$sel"
            fi
            ;;
          *)
            if idx="$(resolve "$reply")"; then
              exec "''${exes[$idx]}" "$@"
            fi
            printf '  no such profile: %s\n\n' "$reply"
            ;;
        esac
      done
    '';
  };
in
runCommand "omp-configured-${lib.getVersion omp}"
  {
    pname = "omp-configured";
    version = lib.getVersion omp;

    passthru = {
      inherit
        allManagedPaths
        defaultsConfig
        enforcedPolicyPaths
        managedDefaultPaths
        managedOwnedPaths
        managedPresetPaths
        omp
        neutralRoot
        platformRoot
        policyConfig
        presets
        untrustedConfig
        yoloConfig
        ;
    };

    meta = omp.meta // {
      description = "Declaratively configured OMP with atyrode model presets";
      mainProgram = "omp";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/share/zsh/site-functions"
    ln -s ${lib.getExe ompDefault} "$out/bin/omp"
    ln -s ${lib.getExe ompBudget} "$out/bin/ompb"
    ln -s ${lib.getExe ompSonnet} "$out/bin/omps"
    ln -s ${lib.getExe ompGpt} "$out/bin/ompg"
    ln -s ${lib.getExe ompClaude} "$out/bin/ompc"
    ln -s ${lib.getExe ompFable} "$out/bin/ompf"
    ln -s ${lib.getExe ompContext} "$out/bin/ompx"
    ln -s ${lib.getExe ompFast} "$out/bin/ompz"
    ln -s ${lib.getExe ompGptSpeed} "$out/bin/ompl"
    ln -s ${lib.getExe ompClaudeSpeed} "$out/bin/ompk"
    ln -s ${lib.getExe ompMixedRegular} "$out/bin/ompn"
    ln -s ${lib.getExe ompMixedSmart} "$out/bin/ompm"
    ln -s ${lib.getExe ompGptOnly} "$out/bin/ompo"
    ln -s ${lib.getExe ompClaudeOnly} "$out/bin/ompe"
    ln -s ${lib.getExe ompHelp} "$out/bin/omph"
    ln -s ${lib.getExe ompUntrusted} "$out/bin/ompu"
    ln -s ${lib.getExe codeLauncher} "$out/bin/code"
    ln -s ${omp}/share/zsh/site-functions/_omp "$out/share/zsh/site-functions/_omp"
  ''
