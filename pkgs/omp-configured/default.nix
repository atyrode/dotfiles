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
      blurb = "Your mutable daily driver (unmanaged)";
      detail = "Runs upstream OMP with whatever your writable ~/.omp config selects. No managed defaults, preset, or policy overlay beyond the blocked update.";
    }
    {
      cmd = "ompz";
      exe = lib.getExe ompFast;
      lead = "mixed";
      group = "mix";
      blurb = "Fast, mixed, latency-first";
      detail = "The fastest competent tiers across both providers at low thinking (Luna/nano/Spark + Sonnet/Haiku), with light single-hop fallbacks. For snappy interactive work; nothing reaches for Sol/Fable/Opus. Mixed pool.";
      preset = presets.fast;
    }
    {
      cmd = "ompb";
      exe = lib.getExe ompBudget;
      lead = "openai";
      group = "gpt";
      blurb = "Cost-conscious routine work";
      detail = "Terra/Luna lead at low thinking; every background role rides gpt-5.4-nano (~5x under Luna). Only the live thread and task worker get a net. Advisor, branch summaries, and autolearn off.";
      preset = presets.budget;
    }
    {
      cmd = "ompg";
      exe = lib.getExe ompGpt;
      lead = "openai";
      group = "gpt";
      blurb = "Difficult work, GPT-led";
      detail = "Sol leads the deliberative roles; a GPT sibling absorbs a capacity blip, then every substantive chain crosses to Fable/Opus. commit/tiny on nano. All-OpenAI lead pool.";
      preset = presets.gpt;
    }
    {
      cmd = "omps";
      exe = lib.getExe ompSonnet;
      lead = "claude";
      group = "claude";
      blurb = "Everyday value, Sonnet-led";
      detail = "Sonnet 5 (intro pricing) leads all but plan/slow, where Opus earns its leverage. Haiku carries background. Chains cross to Terra, Sonnet's price-twin. All-Anthropic pool; features on.";
      preset = presets.sonnet;
    }
    {
      cmd = "ompc";
      exe = lib.getExe ompClaude;
      lead = "claude";
      group = "claude";
      blurb = "Difficult work, Claude-led";
      detail = "ompg's mirror. Fable drives, Opus is the sibling (and leads review), Sonnet/Haiku carry workers, every chain reaches back to Sol/Terra. Load this when OpenAI is dark or Codex credits are spent.";
      preset = presets.claude;
    }
    {
      cmd = "ompf";
      exe = lib.getExe ompFable;
      lead = "claude";
      group = "claude";
      blurb = "Fable-first, deterministic routing";
      detail = "Fable for the primary and deliberative roles with retry and server-side fallback OFF. The contract is: give me Fable, predictably, never silently swap. Background on cheap OpenAI rungs.";
      preset = presets.fable;
    }
    {
      cmd = "ompx";
      exe = lib.getExe ompContext;
      lead = "claude";
      group = "special";
      blurb = "Huge-context (1M) work";
      detail = "For work beyond 372K. Fable/Opus/Sonnet lead (Anthropic owns 1M); gpt-5.4 is the only OpenAI 1M card, used as the cross-net and librarian lead. Haiku (200K) only touches background trivia.";
      preset = presets.context;
    }
    {
      cmd = "ompu";
      exe = lib.getExe ompUntrusted;
      lead = "untrusted";
      group = "special";
      blurb = "Untrusted repositories (isolated)";
      detail = "Dedicated sanitized state, stripped credentials, restricted tools and approvals for deliberately untrusted repositories. Inherits the managed defaults routing.";
    }
  ];
  presetProfiles = builtins.filter (p: p ? preset) paletteProfiles;
  routeSpecs = map (p: "${p.cmd}|${p.blurb}|${p.preset}") presetProfiles;
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
      c_untrusted="''${esc}[38;2;230;130;90m"
      c_mixed="''${esc}[38;2;170;150;225m"
      c_dim="''${esc}[38;2;120;130;145m"
      c_ok="''${esc}[38;2;80;200;120m"
      c_warn="''${esc}[38;2;235;120;90m"
      c_bold="''${esc}[1m"
      c_rst="''${esc}[0m"

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
          special) printf 'specialists' ;;
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

      short_window() {
        case "$1" in
          "5 hours" | "Claude 5 Hour") printf '5h' ;;
          "7 days" | "Claude 7 Day") printf '7d' ;;
          "5 hours (Spark)") printf '5h spark' ;;
          "7 days (Spark)") printf '7d spark' ;;
          "Claude 7 Day (Fable)") printf '7d fable' ;;
          *) printf '%s' "$1" ;;
        esac
      }

      # Green (low use) -> red (near capacity), as an "r;g;b" triple.
      bar_rgb() {
        local p="$1" r g
        if (( p <= 50 )); then
          r=$(( 90 + p * 3 ))
          g=200
        else
          r=235
          g=$(( 200 - (p - 50) * 3 ))
        fi
        (( r > 235 )) && r=235
        (( g < 60 )) && g=60
        printf '%d;%d;70' "$r" "$g"
      }

      # A 10-cell bar: filled cells in the usage gradient, empty cells dim.
      bar() {
        local pct="$1"
        local fill=$(( (pct * 10 + 50) / 100 ))
        (( fill > 10 )) && fill=10
        (( fill < 0 )) && fill=0
        local k rgb
        rgb="$(bar_rgb "$pct")"
        local out="''${esc}[38;2;''${rgb}m"
        for (( k = 0; k < fill; k++ )); do out+='█'; done
        out+="$c_dim"
        for (( k = fill; k < 10; k++ )); do out+='░'; done
        out+="$c_rst"
        printf '%s' "$out"
      }

      # Fill the `usagep` array with a compact per-provider quota panel from
      # `omp usage --json`. Best-effort: on any failure (offline, timeout, not
      # authed, --no-usage) it is left empty and the picker shows just the list.
      fmt_reset() {
        local s="$1"
        (( s < 0 )) && s=0
        if (( s >= 86400 )); then printf '%dd%dh' "$(( s / 86400 ))" "$(( (s % 86400) / 3600 ))"
        elif (( s >= 3600 )); then printf '%dh%dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
        else printf '%dm' "$(( s / 60 ))"; fi
      }

      # Per-provider quota panel: a coloured provider header, then each window's
      # bar, percent used, and time until reset. No redundant "usage" label.
      usagep=()
      build_usage() {
        usagep=()
        (( show_usage_panel == 1 )) || return 0
        local json rows
        json="$(timeout 8 "$omp_bin" usage --json 2>/dev/null)" || return 0
        [[ -n "$json" ]] || return 0
        rows="$(printf '%s' "$json" | jq -r '
            .reports[] | .provider as $p | .limits[]
            | $p + "\t" + .label + "\t"
              + ((.amount.usedFraction * 100) | round | tostring) + "\t"
              + (.scope.tier // "-") + "\t"
              + (((.window.resetsAt / 1000) - now) | floor | tostring)
          ' 2>/dev/null)" || return 0
        [[ -n "$rows" ]] || return 0
        local a b c d e last_provider="" pname pcol note
        while IFS=$'\t' read -r a b c d e; do
          case "$a" in
            openai-codex) pname="Codex"; pcol="$c_openai" ;;
            anthropic) pname="Claude"; pcol="$c_claude" ;;
            *) pname="$a"; pcol="$c_dim" ;;
          esac
          if [[ "$a" != "$last_provider" ]]; then
            usagep+=( "''${pcol}''${c_bold}$pname''${c_rst}" )
            last_provider="$a"
          fi
          note=""
          (( c >= 80 )) && note="  ''${c_warn}tight''${c_rst}"
          [[ "$d" == spark && "$c" -eq 0 ]] && note="  ''${c_ok}free''${c_rst}"
          usagep+=( "$(printf '  %-8s %s %3d%% used  %s%s %s%s%s' \
            "$(short_window "$b")" "$(bar "$c")" "$c" \
            "$c_dim" "$g_reset" "$(fmt_reset "$e")" "$c_rst" "$note")" )
        done <<< "$rows"
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

      lead_glyph() {
        case "$1" in
          openai) printf '%s' "$g_openai" ;;
          claude) printf '%s' "$g_claude" ;;
          mixed) printf '%s' "$g_mixed" ;;
          yours) printf '%s' "$g_yours" ;;
          untrusted) printf '%s' "$g_untrusted" ;;
          *) printf ' ' ;;
        esac
      }
      lead_color() {
        case "$1" in
          openai) printf '%s' "$c_openai" ;;
          claude) printf '%s' "$c_claude" ;;
          mixed) printf '%s' "$c_mixed" ;;
          yours) printf '%s' "$c_yours" ;;
          untrusted) printf '%s' "$c_untrusted" ;;
          *) printf '%s' "$c_dim" ;;
        esac
      }

      # Compact + recolour a routing block for the preview: shorten model names
      # to their tier (gpt-5.6-sol -> sol, claude-fable-5 -> fable), collapse the
      # column padding, and colour each token by provider hue (muted blue for
      # OpenAI, muted orange for Anthropic) with brightness scaled by thinking
      # level (low -> xhigh reads as dim -> bright). Kept narrow so fzf's preview
      # (nowrap) never has to wrap ANSI lines, which it renders incorrectly.
      colorize_routes() {
        gawk -v dim="$c_dim" -v ok="$c_ok" -v bold="$c_bold" -v rst="$c_rst" '
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
          {
            line = $0
            # Reformat the metadata line: bold the thinking level, green/dim the
            # on/off states, so it parses at a glance.
            if (line ~ /^  thinking .* fallback /) {
              match(line, /thinking ([a-z]+)/, m); tl = m[1]
              fb = (line ~ /fallback enabled/) ? "on" : "off"; fbc = (fb == "on") ? ok : dim
              ad = (line ~ /advisor on/) ? "on" : "off"; adc = (ad == "on") ? ok : dim
              print dim "  thinking " bold tl rst dim "    fallback " fbc fb dim "    advisor " adc ad rst
              next
            }
            gsub(/ +→/, " →", line)
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

      # Arrow-key picker via fzf: a truecolor list with Nerd Font provider
      # glyphs and soft group labels at the top, the usage panel in the footer,
      # and each profile's detail + colourised role -> model routing in the
      # preview. Sets picked_idx, or leaves it empty when cancelled.
      picked_idx=""
      fzf_pick() {
        picked_idx=""
        build_usage
        local footer=""
        local -a footer_args=()
        if (( ''${#usagep[@]} > 0 )); then
          printf -v footer '%s\n' "''${usagep[@]}"
          footer="''${footer%$'\n'}"
          footer_args=( --footer="$footer" --footer-border=top )
        fi
        local prevdir
        prevdir="$(mktemp -d)"
        local i col gly rows="" block glabel labelcol last_group=""
        for (( i = 0; i < count; i++ )); do
          col="$(lead_color "''${leads[$i]}")"
          gly="$(lead_glyph "''${leads[$i]}")"
          glabel=""
          if [[ "''${groups[$i]}" != "$last_group" ]]; then
            glabel="$(group_label "''${groups[$i]}")"
            last_group="''${groups[$i]}"
          fi
          labelcol="$(printf '%-10s' "$glabel")"
          rows+="$(printf '%s\t%s%s%s  %s%s%s  %s%-5s%s  %s%s%s' \
            "''${names[$i]}" \
            "$c_dim" "$labelcol" "$c_rst" \
            "$col" "$gly" "$c_rst" \
            "$c_bold" "''${names[$i]}" "$c_rst" \
            "$c_dim" "''${blurbs[$i]}" "$c_rst")"$'\n'
          {
            printf '%s%s  %s%s%s\n\n' "$col" "$gly" "$c_bold" "''${names[$i]}" "$c_rst"
            printf '%s%s%s\n\n' "$c_dim" "''${blurbs[$i]}" "$c_rst"
            printf '%s\n' "''${details[$i]}"
            if [[ -f "$routes_plain" ]]; then
              block="$(sed -n "/^''${names[$i]}  /,/^\$/p" "$routes_plain")"
              [[ -n "$block" ]] && printf '\n%s%s%s\n' \
                "$c_dim" "$(printf '%s' "$block" | colorize_routes)" "$c_rst"
            fi
          } > "$prevdir/''${names[$i]}"
        done
        local theme chosen cmd
        theme='fg:-1,bg:-1,fg+:#ffffff,bg+:#1b212b,hl:#62a7ff,hl+:#8ec7ff'
        theme+=',pointer:#ff9f52,marker:#ff9f52,prompt:#ff9f52,spinner:#ff9f52'
        theme+=',border:#3a4453,label:#9aa4b1,info:#69727e'
        theme+=',footer:#9aa4b1,footer-border:#3a4453'
        theme+=',gutter:-1,preview-border:#3a4453'
        chosen="$(printf '%s' "$rows" | fzf \
          --ansi --layout=reverse --height=100% --border=rounded \
          --border-label=" code $g_point pick a launcher " \
          --prompt="$g_search  " --pointer="$g_point" --marker='+' --info=inline \
          --delimiter=$'\t' --with-nth=2 \
          --preview="cat $prevdir/{1}" --preview-window='right:52%:nowrap:border-left' \
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
        [[ -n "$picked_idx" ]] && exec "''${exes[$picked_idx]}" "$@"
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
    ln -s ${lib.getExe ompHelp} "$out/bin/omph"
    ln -s ${lib.getExe ompUntrusted} "$out/bin/ompu"
    ln -s ${lib.getExe codeLauncher} "$out/bin/code"
    ln -s ${omp}/share/zsh/site-functions/_omp "$out/share/zsh/site-functions/_omp"
  ''
