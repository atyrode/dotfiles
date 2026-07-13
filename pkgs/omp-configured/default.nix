{
  bash,
  cacert,
  code-tui,
  coreutils,
  findutils,
  gitMinimal,
  gnugrep,
  jq,
  lib,
  omp,
  omp-agents,
  patch,
  python3,
  runCommand,
  writeShellApplication,
  writeText,
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
              'OMP --no-extensions is unavailable for managed sessions because it disables the Nix-owned settings guard, agents, and rules. Use a dedicated restricted launcher instead.' >&2
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
  # Zero-preset managed launcher: applies the platform extensions + managed
  # defaults + policy to an arbitrary one-shot `--config`, with no preset
  # overlay. The code picker's generator points CODE_OMP here so a synthesised
  # profile launches through the same managed layering as a preset.
  ompManaged = mkOmpCommand "omp-managed" [ ];

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
    runCommand "omp-generated-profiles"
      { nativeBuildInputs = [ (python3.withPackages (ps: [ ps.pyyaml ])) ]; }
      ''
        mkdir -p "$out/share/omp"
        MODELS_YML=${../../omp/models.yml} \
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
  # code-tui manifest: accent colour (by lane/provider) and glyph (by intended
  # use), mirrored from the retired fzf picker. nfGlyph decodes a Nerd Font
  # codepoint via JSON so no raw private-use bytes live in this file.
  nfGlyph = cp: builtins.fromJSON ''"\u${cp}"'';
  profileColor =
    cmd:
    if builtins.elem cmd [ "ompz" "ompn" "ompm" ] then
      "#aa96e1" # mixed — purple
    else if builtins.elem cmd [ "ompl" "ompb" "ompg" "ompo" ] then
      "#62a7ff" # gpt-led — blue
    else if builtins.elem cmd [ "ompk" "omps" "ompc" "ompe" ] then
      "#ff9f52" # claude-led — orange
    else if builtins.elem cmd [ "ompf" "ompx" ] then
      "#46bec8" # specialist — teal
    else if cmd == "ompu" then
      "#d05c60" # untrusted — red
    else
      "#78c8aa"; # yours — green
  profileGlyph =
    cmd:
    if builtins.elem cmd [ "ompz" "ompl" "ompk" ] then
      nfGlyph "f0e7" # bolt — speed
    else if builtins.elem cmd [ "ompn" "ompb" "omps" ] then
      nfGlyph "f085" # cogs — routine
    else if builtins.elem cmd [ "ompm" "ompg" "ompc" ] then
      nfGlyph "f0eb" # lightbulb — smart
    else if builtins.elem cmd [ "ompo" "ompe" ] then
      nfGlyph "f127" # broken link — pure pool
    else if cmd == "ompf" then
      nfGlyph "f08d" # thumbtack — deterministic
    else if cmd == "ompx" then
      nfGlyph "f02d" # book — huge context
    else if cmd == "ompu" then
      nfGlyph "f023" # lock — untrusted
    else if cmd == "omp" then
      nfGlyph "f007" # user — yours
    else
      nfGlyph "f074"; # shuffle
  groupLabel =
    g:
    {
      mix = "mixed";
      gpt = "gpt-led";
      claude = "claude-led";
      special = "special";
    }
    .${g} or g;
  codeProfilesTsv = writeText "code-profiles.tsv" (
    lib.concatMapStringsSep "\n" (
      p:
      lib.concatStringsSep "\t" [
        p.cmd
        p.blurb
        p.detail
        (groupLabel p.group)
        p.exe
        (profileColor p.cmd)
        (profileGlyph p.cmd)
      ]
    ) paletteProfiles
  );

  # The browsable profiles wiki (issue #79): a self-contained routes.html
  # rendered from models.yml (catalog + cost) + routes.plain + PROFILES.md.
  # Built here so it can't drift; opened via `code --wiki`.
  profilesWiki =
    runCommand "omp-profiles-wiki"
      { nativeBuildInputs = [ (python3.withPackages (ps: [ ps.pyyaml ])) ]; }
      ''
        mkdir -p "$out/share/omp"
        MODELS_YML=${../../omp/models.yml} \
        ROUTES=${routesHelp}/share/omp/routes.plain \
        PROFILES_MD=${../../omp/PROFILES.md} \
        CODE_PROFILES=${codeProfilesTsv} \
          python3 ${./generate-wiki.py} > "$out/share/omp/routes.html"
      '';

  codeLauncher = writeShellApplication {
    name = "code";
    runtimeInputs = [ coreutils ];
    text = ''
      omp_bin=${lib.escapeShellArg (lib.getExe omp)}
      export CODE_PROFILES=${codeProfilesTsv}
      export CODE_ROUTES=${routesHelp}/share/omp/routes.plain
      export CODE_GENERATED=${generatedProfiles}/share/omp/generated.plain
      export CODE_OMP=${lib.getExe ompManaged}
      export CODE_USAGE="$omp_bin usage --json"
      # Bare omp for the picker's prompt→profile evaluator (a cheap one-shot with an
      # explicit --model): the managed launcher (CODE_OMP) would override the model.
      # Respect a preset value so it can be pointed at a different binary/wrapper.
      export CODE_OMP_EVAL="''${CODE_OMP_EVAL:-$omp_bin}"

      names=( ${lib.escapeShellArgs (map (p: p.cmd) paletteProfiles)} )
      exes=( ${lib.escapeShellArgs (map (p: p.exe) paletteProfiles)} )
      blurbs=( ${lib.escapeShellArgs (map (p: p.blurb) paletteProfiles)} )
      groups=( ${lib.escapeShellArgs (map (p: groupLabel p.group) paletteProfiles)} )
      count=''${#names[@]}

      # Map a selector (bare|name|1-based number|single letter) to a 0-based index.
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

      print_list() {
        local i last=""
        for (( i = 0; i < count; i++ )); do
          if [[ "''${groups[$i]}" != "$last" ]]; then
            last="''${groups[$i]}"
            [[ -n "$last" ]] && printf '  %s\n' "$last"
          fi
          printf '  %-6s %s\n' "''${names[$i]}" "''${blurbs[$i]}"
        done
      }

      usage() {
        printf '%s\n' \
          'code - pick an OMP launcher (or build one) and run it' \
          "" \
          'usage:' \
          '  code                    open the picker / profile generator' \
          '  code <profile>          run that launcher (name, number, or letter)' \
          '  code <profile> [args]   run it, forwarding all extra args' \
          '  code -l, --list         print the launcher palette and exit' \
          '  code -w, --wiki         serve the profiles wiki on localhost' \
          '  code -U, --no-usage     open without fetching the usage panel' \
          '  code -h, --help         this help' \
          "" \
          'In the picker: Tab switches profiles <-> generator, arrows move,' \
          '? shows all keys, Enter launches. A first argument that is not a' \
          'profile opens the picker and forwards all args to your choice.'
      }

      # Serve the wiki over HTTP on localhost rather than handing back a file
      # path — so it also works on a headless VPS (forward the port over SSH).
      # Bound to 127.0.0.1 only; set CODE_WIKI_PORT to change the port.
      open_wiki() {
        local wiki=${profilesWiki}/share/omp/routes.html
        local port="''${CODE_WIKI_PORT:-8765}"
        local dir
        dir="$(mktemp -d)"
        cp "$wiki" "$dir/index.html"
        trap 'rm -rf "$dir"' EXIT
        local url="http://127.0.0.1:$port/"
        printf 'code: serving the profiles wiki at %s\n' "$url"
        printf 'code: from another machine, forward it:  ssh -L %s:127.0.0.1:%s <this-host>\n' "$port" "$port"
        printf 'code: Ctrl-C to stop.\n'
        if command -v xdg-open >/dev/null 2>&1; then
          xdg-open "$url" >/dev/null 2>&1 &
        elif command -v open >/dev/null 2>&1; then
          open "$url" >/dev/null 2>&1 &
        fi
        ${python3}/bin/python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" || true
      }

      case "''${1:-}" in
        -h | --help) usage; exit 0 ;;
        -l | --list) print_list; exit 0 ;;
        -w | --wiki) open_wiki; exit 0 ;;
        -U | --no-usage) export CODE_USAGE=""; shift ;;
      esac

      # A resolvable first arg launches that profile directly (forwarding the
      # rest); anything else opens the picker with the args passed through.
      if (( $# > 0 )) && idx="$(resolve "$1")"; then
        shift
        exec "''${exes[$idx]}" "$@"
      fi

      if [[ ! -t 0 || ! -t 1 ]]; then
        printf 'code: no profile given and no interactive terminal.\n\n' >&2
        print_list >&2
        exit 2
      fi

      exec ${lib.getExe code-tui} "$@"
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
    mkdir -p "$out/bin" "$out/share/zsh/site-functions" "$out/share/omp"
    ln -s ${profilesWiki}/share/omp/routes.html "$out/share/omp/routes.html"
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
