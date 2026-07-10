#!/usr/bin/env bash
set -euo pipefail

state_root="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/agent-tools-migration"
marker="$state_root/migration-v2.complete"
dry_run="${AGENT_TOOLS_DRY_RUN:-0}"
backup_dir=""

fail() {
  printf 'Agent tools migration refused: %s\n' "$*" >&2
  exit 1
}

is_nix_link() {
  local path="$1"
  [[ -L "$path" ]] || return 1
  local target
  target="$(readlink "$path")"
  [[ "$target" == /nix/store/* ]]
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

ensure_backup_dir() {
  [[ -n "$backup_dir" ]] && return 0
  backup_dir="$state_root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if [[ "$dry_run" != "1" ]]; then
    mkdir -p "$backup_dir"
    chmod 700 "$state_root" "$backup_dir"
  fi
}

backup_move() {
  local source="$1"
  local relative="${source#"$HOME"/}"
  ensure_backup_dir
  printf 'Backing up %s -> %s/%s\n' "$source" "$backup_dir" "$relative"
  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi
  mkdir -p "$backup_dir/${relative%/*}"
  mv "$source" "$backup_dir/$relative"
}

backup_copy() {
  local source="$1"
  local relative="${source#"$HOME"/}"
  ensure_backup_dir
  printf 'Backing up %s -> %s/%s\n' "$source" "$backup_dir" "$relative"
  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi
  mkdir -p "$backup_dir/${relative%/*}"
  cp -p "$source" "$backup_dir/$relative"
}

preflight_binary() {
  local name="$1"
  local path="$HOME/.local/bin/$name"
  path_exists "$path" || return 0
  is_nix_link "$path" && return 0

  [[ -f "$path" || -L "$path" ]] ||
    fail "$path is not a regular file or symlink; move it manually"
}

preflight_bigpowers() {
  local plugin_root="$HOME/.omp/plugins"
  local package="$plugin_root/node_modules/bigpowers"
  path_exists "$package" || return 0

  [[ ! -L "$plugin_root" ]] || fail "$plugin_root is a symlink"
  [[ -f "$plugin_root/package.json" ]] || fail "$package exists without a plugin package manifest"

  jq -e '
    ((.dependencies // {}) | keys | sort) == ["bigpowers"] and
    ((.devDependencies // {}) | length) == 0 and
    ((.optionalDependencies // {}) | length) == 0
  ' "$plugin_root/package.json" >/dev/null ||
    fail "$plugin_root contains Bigpowers alongside other top-level plugins"
}

preflight_config() {
  local config="$HOME/.omp/agent/config.yml"
  [[ -f "$marker" || ! -f "$config" ]] && return 0
  yq eval '.' "$config" >/dev/null || fail "$config is not valid YAML"
}

preflight_binary omp
preflight_binary herdr
preflight_bigpowers
preflight_config

for name in omp herdr; do
  path="$HOME/.local/bin/$name"
  if path_exists "$path" && ! is_nix_link "$path"; then
    backup_move "$path"
  fi
done

plugin_root="$HOME/.omp/plugins"
if path_exists "$plugin_root/node_modules/bigpowers"; then
  backup_move "$plugin_root"
fi

managed_agent_names=(
  architect-deep
  debugger-deep
  designer
  designer-deep
  explore
  librarian
  plan
  reviewer
  reviewer-deep
  sonic
  task
  Tester
  tester-deep
)

for name in "${managed_agent_names[@]}"; do
  path="$HOME/.omp/agent/agents/$name.md"
  if path_exists "$path" && ! is_nix_link "$path"; then
    backup_move "$path"
  fi
done

managed_paths=(
  "$HOME/.omp/agent/extensions/herdr-omp-agent-state.ts"
  "$HOME/.omp/agent/rules/no-shell-text-surgery.md"
  "$HOME/.omp/agent/gpt56-only.yml"
  "$HOME/.omp/agent/gpt56-opus-fallback.yml"
  "$HOME/.omp/agent/fable-only.yml"
  "$HOME/.omp/agent/managed-skills/ts-react-dead-code-sweep"
)

for path in "${managed_paths[@]}"; do
  if path_exists "$path" && ! is_nix_link "$path"; then
    backup_move "$path"
  fi
done

config="$HOME/.omp/agent/config.yml"
if [[ ! -f "$marker" && -f "$config" ]]; then
  backup_copy "$config"
  printf 'Trimming Nix-managed settings from %s\n' "$config"
  if [[ "$dry_run" != "1" ]]; then
    temporary="$config.agent-tools-migration.$$"
    yq eval '
      del(
        .providers.webSearch,
        .tools.approvalMode,
        .secrets.enabled,
        .symbolPreset,
        .colorBlindMode,
        .modelRoles,
        .retry,
        .personality,
        .advisor,
        .stt,
        .branchSummary,
        .autolearn,
        .github,
        .checkpoint,
        .statusLine,
        .terminal,
        .tui,
        .display,
        .codexResets,
        .task,
        .memory,
        .theme,
        .browser,
        .proseOnlyThinking,
        .defaultThinkingLevel
      )
    ' "$config" > "$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$config"
  fi
fi

if [[ "$dry_run" != "1" ]]; then
  mkdir -p "$state_root"
  chmod 700 "$state_root"
  printf 'completed\n' > "$marker"
  chmod 600 "$marker"
fi
