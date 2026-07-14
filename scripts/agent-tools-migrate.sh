#!/usr/bin/env bash
set -euo pipefail

migration_name="migration-v2"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/agent-tools-migration"
pending="$state_root/$migration_name.pending"
complete="$state_root/$migration_name.complete"
dry_run="${AGENT_TOOLS_DRY_RUN:-0}"
failpoint="${AGENT_TOOLS_MIGRATION_FAILPOINT:-}"
transient_dirs=()
transient_files=()

cleanup_transients() {
  local path
  for path in "${transient_files[@]}"; do
    if [[ -f "$path" && ! -L "$path" ]]; then
      rm -f -- "$path"
    fi
  done
  for path in "${transient_dirs[@]}"; do
    if [[ -d "$path" && ! -L "$path" ]]; then
      rm -rf -- "$path"
    fi
  done
}

trap cleanup_transients EXIT

fail() {
  printf 'Agent tools migration refused: %s\n' "$*" >&2
  exit 1
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

is_home_manager_link() {
  local path="$1"
  [[ -L "$path" ]] || return 1
  local target
  target="$(readlink "$path")"
  [[ "$target" == /nix/store/*-home-manager-files/* ]]
}

maybe_fail() {
  local phase="$1"
  if [[ "$failpoint" == "$phase" ]]; then
    printf 'Agent tools migration interrupted at test failpoint: %s\n' "$phase" >&2
    exit 75
  fi
}

ensure_state_root() {
  if [[ -L "$state_root" ]]; then
    fail "$state_root is a symlink"
  fi
  mkdir -p "$state_root"
  chmod 700 "$state_root"
}

acquire_lock() {
  ensure_state_root
  exec 9<"$state_root"
  flock -n 9 || fail "another agent tools migration is running"
}

source_identity() {
  local source="$1"
  local digest
  if [[ -L "$source" ]]; then
    digest="$(readlink "$source" | sha256sum)"
    printf 'symlink:%s\n' "${digest%% *}"
  elif [[ -f "$source" ]]; then
    digest="$(sha256sum "$source")"
    printf 'file:%s\n' "${digest%% *}"
  elif [[ -d "$source" ]]; then
    printf 'directory\n'
  else
    fail "$source has an unsupported type"
  fi
}

ensure_safe_backup_parent() {
  local transaction_dir="$1"
  local relative="$2"
  local current="$transaction_dir/backup"
  local parent="${relative%/*}"
  local component
  local -a components=()
  IFS=/ read -r -a components <<<"$parent"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != . && "$component" != .. ]] ||
      fail "receipt contains an unsafe backup path"
    current="$current/$component"
    if path_exists "$current"; then
      [[ -d "$current" && ! -L "$current" ]] || fail "$current is not a safe receipt directory"
    else
      mkdir "$current"
      chmod 700 "$current"
    fi
  done
}

is_allowed_link_path() {
  case "$1" in
    .omp/agent/agents/architect-deep.md | .omp/agent/agents/debugger-deep.md | \
      .omp/agent/agents/designer.md | .omp/agent/agents/designer-deep.md | \
      .omp/agent/agents/explore.md | .omp/agent/agents/librarian.md | \
      .omp/agent/agents/plan.md | .omp/agent/agents/reviewer.md | \
      .omp/agent/agents/reviewer-deep.md | .omp/agent/agents/sonic.md | \
      .omp/agent/agents/task.md | .omp/agent/agents/Tester.md | \
      .omp/agent/agents/tester-deep.md | \
      .omp/agent/extensions/herdr-omp-agent-state.ts | \
      .omp/agent/extensions/managed-settings-guard.ts | \
      .omp/agent/rules/no-shell-text-surgery.md)
      return 0
      ;;
  esac
  return 1
}

is_allowed_absent_path() {
  case "$1" in
    .local/bin/omp | .local/bin/herdr | .omp/plugins | .omp/agent/mcp.json | \
      .omp/agent/gpt56-only.yml | .omp/agent/gpt56-opus-fallback.yml | \
      .omp/agent/fable-only.yml | .omp/agent/agents/architect-deep.md | \
      .omp/agent/agents/debugger-deep.md | .omp/agent/agents/designer.md | \
      .omp/agent/agents/designer-deep.md | .omp/agent/agents/explore.md | \
      .omp/agent/agents/librarian.md | .omp/agent/agents/plan.md | \
      .omp/agent/agents/reviewer.md | .omp/agent/agents/reviewer-deep.md | \
      .omp/agent/agents/sonic.md | .omp/agent/agents/task.md | \
      .omp/agent/agents/Tester.md | .omp/agent/agents/tester-deep.md | \
      .omp/agent/extensions/herdr-omp-agent-state.ts | \
      .omp/agent/extensions/managed-settings-guard.ts | \
      .omp/agent/rules/no-shell-text-surgery.md | \
      .omp/agent/managed-skills/ts-react-dead-code-sweep)
      return 0
      ;;
  esac
  return 1
}

validate_receipt() {
  local transaction_dir="$1"
  local receipt="$transaction_dir/receipt.tsv"
  [[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] ||
    fail "$transaction_dir is not a migration receipt directory"
  [[ -f "$receipt" && ! -L "$receipt" ]] || fail "$receipt is missing or unsafe"
  local receipt_dir
  for receipt_dir in "$transaction_dir/backup" "$transaction_dir/work"; do
    [[ -d "$receipt_dir" && ! -L "$receipt_dir" ]] ||
      fail "$receipt_dir is not a safe receipt directory"
  done

  local version_count=0
  local config_count=0
  local record kind final relative detail extra
  local -A seen=()
  while IFS=$'\t' read -r record kind final relative detail extra; do
    case "$record" in
      version)
        [[ "$kind" == "1" && -z "$final$relative$detail$extra" ]] ||
          fail "$receipt has an unsupported version record"
        version_count=$((version_count + 1))
        ;;
      action)
        [[ -z "$extra" && -n "$relative" && -z "${seen[$relative]:-}" ]] ||
          fail "$receipt has a duplicate or malformed action"
        seen[$relative]=1
        case "$kind:$final" in
          move:link)
            is_allowed_link_path "$relative" || fail "$receipt contains an unsafe link path"
            [[ "$detail" == directory || "$detail" =~ ^(file|symlink):[0-9a-f]{64}$ ]] ||
              fail "$receipt has an invalid link action"
            ;;
          move:absent)
            is_allowed_absent_path "$relative" || fail "$receipt contains an unsafe retired path"
            [[ "$detail" == directory || "$detail" =~ ^(file|symlink):[0-9a-f]{64}$ ]] ||
              fail "$receipt has an invalid retired-path action"
            ;;
          config:transform)
            [[ "$relative" =~ ^\.omp/agent/config\.ya?ml$ && "$detail" =~ ^[0-9a-f]{64}$ ]] ||
              fail "$receipt has an invalid config transform"
            config_count=$((config_count + 1))
            ;;
          config:absent)
            [[ "$relative" =~ ^\.omp/agent/config\.ya?ml$ && "$detail" == "-" ]] ||
              fail "$receipt has an invalid absent-config record"
            config_count=$((config_count + 1))
            ;;
          *)
            fail "$receipt contains an unknown action"
            ;;
        esac
        ;;
      *)
        fail "$receipt contains an unknown record"
        ;;
    esac
  done < "$receipt"

  [[ "$version_count" -eq 1 && "$config_count" -eq 1 ]] ||
    fail "$receipt is incomplete"
}

validate_completed_receipt() {
  local transaction_dir="$1"
  local receipt="$transaction_dir/receipt.tsv"

  if [[ -f "$receipt" && ! -L "$receipt" && ! -s "$receipt" ]]; then
    local receipt_dir
    [[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] ||
      fail "$transaction_dir is not a migration receipt directory"
    for receipt_dir in "$transaction_dir/backup" "$transaction_dir/work"; do
      [[ -d "$receipt_dir" && ! -L "$receipt_dir" ]] ||
        fail "$receipt_dir is not a safe receipt directory"
      local -a entries=()
      shopt -s dotglob nullglob
      entries=("$receipt_dir"/*)
      shopt -u dotglob nullglob
      [[ "${#entries[@]}" -eq 0 ]] ||
        fail "$transaction_dir has an empty receipt with retained migration data"
    done
    return 0
  fi

  validate_receipt "$transaction_dir"
}

validate_terminal_state() {
  if path_exists "$pending" && path_exists "$complete"; then
    fail "both pending and completed migration state exist under $state_root"
  fi

  if path_exists "$complete"; then
    if [[ -f "$complete" && ! -L "$complete" ]]; then
      [[ "$(cat "$complete")" == "completed" ]] || fail "$complete is not a recognized legacy marker"
    else
      validate_completed_receipt "$complete"
    fi
    return 0
  fi

  return 1
}

check_for_orphaned_legacy_backup() {
  local candidate
  shopt -s nullglob
  for candidate in "$state_root"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-*; do
    if [[ -d "$candidate" ]]; then
      shopt -u nullglob
      fail "found an unfinished legacy backup at $candidate; review it before retrying"
    fi
  done
  shopt -u nullglob
}

preflight_binary() {
  local name="$1"
  local path="$HOME/.local/bin/$name"
  path_exists "$path" || return 0
  [[ -f "$path" || -L "$path" ]] ||
    fail "$path is not a regular file or symlink; move it manually"
}

preflight_bigpowers() {
  local plugin_root="$HOME/.omp/plugins"
  local package="$plugin_root/node_modules/bigpowers"
  path_exists "$package" || return 0

  [[ -d "$plugin_root" && ! -L "$plugin_root" ]] || fail "$plugin_root is not a safe directory"
  [[ -d "$package" && ! -L "$package" ]] || fail "$package is not a safe package directory"
  [[ -f "$plugin_root/package.json" && ! -L "$plugin_root/package.json" ]] ||
    fail "$package exists without a safe plugin package manifest"
  jq -e '
    type == "object" and
    ((.dependencies // {}) | keys | sort) == ["bigpowers"] and
    ((.devDependencies // {}) | length) == 0 and
    ((.optionalDependencies // {}) | length) == 0 and
    ((keys - ["dependencies", "devDependencies", "optionalDependencies"]) | length) == 0
  ' "$plugin_root/package.json" >/dev/null ||
    fail "$plugin_root contains mixed or customized plugin state"

  local entry
  shopt -s dotglob nullglob
  for entry in "$plugin_root"/*; do
    case "${entry##*/}" in
      node_modules | package.json | bun.lock | bun.lockb | package-lock.json | omp-plugins.lock.json) ;;
      *)
        shopt -u dotglob nullglob
        fail "$plugin_root contains mixed or customized plugin state"
        ;;
    esac
  done
  shopt -u dotglob nullglob
}

is_exact_bigpowers_mcp_workaround() {
  local config="$HOME/.omp/agent/mcp.json"
  [[ -f "$config" && ! -L "$config" ]] || return 1
  jq -e '
    (.mcpServers // {}) == {} and
    (.disabledServers // []) == ["bigpowers-mcp"] and
    ((keys - ["$schema", "mcpServers", "disabledServers"]) | length) == 0
  ' "$config" >/dev/null 2>&1
}

record_move_if_needed() {
  local receipt="$1"
  local final="$2"
  local relative="$3"
  local source="$HOME/$relative"
  if path_exists "$source" && ! is_home_manager_link "$source"; then
    printf 'action\tmove\t%s\t%s\t%s\n' \
      "$final" "$relative" "$(source_identity "$source")" >> "$receipt"
  fi
}

discover_plan() {
  local receipt="$1"
  preflight_binary omp
  preflight_binary herdr
  preflight_bigpowers

  printf 'version\t1\n' > "$receipt"
  record_move_if_needed "$receipt" absent .local/bin/omp
  record_move_if_needed "$receipt" absent .local/bin/herdr

  if path_exists "$HOME/.omp/plugins/node_modules/bigpowers"; then
    record_move_if_needed "$receipt" absent .omp/plugins
  fi
  if is_exact_bigpowers_mcp_workaround; then
    record_move_if_needed "$receipt" absent .omp/agent/mcp.json
  fi

  local name
  for name in \
    architect-deep debugger-deep designer designer-deep explore librarian plan \
    reviewer reviewer-deep sonic task Tester tester-deep
  do
    record_move_if_needed "$receipt" absent ".omp/agent/agents/$name.md"
  done

  record_move_if_needed "$receipt" absent .omp/agent/extensions/herdr-omp-agent-state.ts
  record_move_if_needed "$receipt" absent .omp/agent/extensions/managed-settings-guard.ts
  record_move_if_needed "$receipt" absent .omp/agent/rules/no-shell-text-surgery.md
  record_move_if_needed "$receipt" absent .omp/agent/gpt56-only.yml
  record_move_if_needed "$receipt" absent .omp/agent/gpt56-opus-fallback.yml
  record_move_if_needed "$receipt" absent .omp/agent/fable-only.yml
  record_move_if_needed "$receipt" absent .omp/agent/managed-skills/ts-react-dead-code-sweep

  local config_yml="$HOME/.omp/agent/config.yml"
  local config_yaml="$HOME/.omp/agent/config.yaml"
  if path_exists "$config_yml" && path_exists "$config_yaml"; then
    fail "both $config_yml and $config_yaml exist; preserve both and resolve the legacy fallback manually"
  fi
  local config="$config_yml"
  local config_relative=".omp/agent/config.yml"
  if ! path_exists "$config" && path_exists "$config_yaml"; then
    config="$config_yaml"
    config_relative=".omp/agent/config.yaml"
  fi
  if path_exists "$config"; then
    [[ -f "$config" && ! -L "$config" ]] || fail "$config is not a regular file"
    yq eval '.' "$config" >/dev/null || fail "$config is not valid YAML"
    local legacy_theme
    legacy_theme="$(yq eval '.theme | select(tag == "!!str")' "$config")"
    if [[ -n "$legacy_theme" && "$legacy_theme" != dark && "$legacy_theme" != light ]]; then
      fail "$config uses a legacy scalar custom theme; rewrite it as theme.dark or theme.light before retrying"
    fi
    local digest
    digest="$(sha256sum "$config")"
    digest="${digest%% *}"
    printf 'action\tconfig\ttransform\t%s\t%s\n' "$config_relative" "$digest" >> "$receipt"
  else
    printf 'action\tconfig\tabsent\t.omp/agent/config.yml\t-\n' >> "$receipt"
  fi

  chmod 600 "$receipt"
  validate_receipt "$(dirname "$receipt")"
}

for_each_action() {
  local transaction_dir="$1"
  local callback="$2"
  local record kind final relative detail extra
  while IFS=$'\t' read -r record kind final relative detail extra; do
    [[ "$record" == "action" ]] || continue
    "$callback" "$transaction_dir" "$kind" "$final" "$relative" "$detail"
  done < "$transaction_dir/receipt.tsv"
}

render_transformed_config() {
  local source="$1"
  local destination="$2"
  local theme_path=".theme.dark"
  if [[ "$(yq eval '.theme | tag' "$source")" == "!!str" ]]; then
    theme_path=".theme"
  fi
  yq eval "
    del(
      .providers.webSearch,
      .tools.approvalMode,
      .tools.approval,
      .secrets.enabled,
      .symbolPreset,
      .colorBlindMode,
      .modelRoles,
      .retry.enabled,
      .retry.modelFallback,
      .retry.fallbackRevertPolicy,
      .retry.fallbackChains,
      .personality,
      .advisor.enabled,
      .advisor.subagents,
      .advisor.syncBacklog,
      .stt.enabled,
      .branchSummary.enabled,
      .autolearn.enabled,
      .autolearn.autoContinue,
      .github.enabled,
      .checkpoint.enabled,
      .statusLine.preset,
      .statusLine.compactThinkingLevel,
      .statusLine.transparent,
      .terminal.showProgress,
      .tui.tight,
      .display.shimmer,
      .display.showTokenUsage,
      .display.cacheMissMarker,
      .codexResets.autoRedeem,
      .[\"codexResets.autoRedeem\"],
      .task.showResolvedModelBadge,
      .task.agentModelOverrides,
      .task.disabledAgents,
      .task.isolation,
      .memory.backend,
      $theme_path,
      .browser.headless,
      .browser.enabled,
      .proseOnlyThinking,
      .defaultThinkingLevel
    )
  " "$source" > "$destination"
  yq eval '.' "$destination" >/dev/null
  chmod 600 "$destination"
}

validate_transformed_config() {
  local transaction_dir="$1"
  local relative="$2"
  local original="$transaction_dir/backup/$relative"
  local transformed="$transaction_dir/work/config.transformed.yml"
  [[ -f "$original" && ! -L "$original" && -f "$transformed" && ! -L "$transformed" ]] ||
    fail "the transformed config receipt is missing or unsafe"
  local expected
  expected="$(mktemp "$transaction_dir/work/config.expected.XXXXXX")"
  transient_files+=("$expected")
  render_transformed_config "$original" "$expected"
  cmp -s "$transformed" "$expected" ||
    fail "$transformed does not match the digest-verified original config"
  rm -f -- "$expected"
}

validate_pending_action() {
  local transaction_dir="$1"
  local kind="$2"
  local final="$3"
  local relative="$4"
  local detail="$5"
  local source="$HOME/$relative"
  local backup="$transaction_dir/backup/$relative"

  if [[ "$kind" == "move" ]]; then
    ensure_safe_backup_parent "$transaction_dir" "$relative"
    if path_exists "$backup"; then
      [[ "$(source_identity "$backup")" == "$detail" ]] ||
        fail "$backup changed while migration was pending"
      if ! path_exists "$source"; then
        return 0
      fi
      if [[ "$final" == "link" ]] && is_home_manager_link "$source"; then
        return 0
      fi
      fail "$source and its migration backup both exist; preserve both and resolve the collision"
    fi
    path_exists "$source" || fail "$source and its planned migration backup are both missing"
    [[ "$(source_identity "$source")" == "$detail" ]] ||
      fail "$source changed after the migration receipt was created"
    if [[ "$relative" == .omp/plugins ]]; then
      preflight_bigpowers
    fi
    local backup_parent="$transaction_dir/backup/${relative%/*}"
    [[ "$(stat -c %d "$(dirname "$source")")" == "$(stat -c %d "$backup_parent")" ]] ||
      fail "$source cannot be backed up atomically because the state directory is on another filesystem"
    return 0
  fi

  if [[ "$final" == "absent" ]]; then
    path_exists "$source" && fail "$source appeared after the migration receipt was created"
    return 0
  fi

  local original="$transaction_dir/backup/$relative"
  local transformed="$transaction_dir/work/config.transformed.yml"
  ensure_safe_backup_parent "$transaction_dir" "$relative"
  [[ ! -L "$transformed" ]] || fail "$transformed is an unsafe symlink"
  if path_exists "$original"; then
    [[ -f "$original" && ! -L "$original" && -f "$source" && ! -L "$source" ]] ||
      fail "$source or its config backup has an unsafe type"
    local original_digest
    original_digest="$(sha256sum "$original")"
    original_digest="${original_digest%% *}"
    [[ "$original_digest" == "$detail" ]] || fail "$original no longer matches its receipt digest"
    if [[ -f "$transformed" ]]; then
      validate_transformed_config "$transaction_dir" "$relative"
      cmp -s "$source" "$original" || cmp -s "$source" "$transformed" ||
        fail "$source changed while migration was pending; preserve both versions and resolve it manually"
    else
      cmp -s "$source" "$original" ||
        fail "$source changed while migration was pending; preserve both versions and resolve it manually"
    fi
  else
    [[ -f "$source" && ! -L "$source" ]] || fail "$source disappeared while migration was pending"
    local current_digest
    current_digest="$(sha256sum "$source")"
    current_digest="${current_digest%% *}"
    [[ "$current_digest" == "$detail" ]] ||
      fail "$source changed after the migration receipt was created"
  fi
}

move_count=0
execute_pending_action() {
  local transaction_dir="$1"
  local kind="$2"
  local final="$3"
  local relative="$4"
  local detail="$5"
  local source="$HOME/$relative"
  local backup="$transaction_dir/backup/$relative"

  if [[ "$kind" == "move" ]]; then
    ensure_safe_backup_parent "$transaction_dir" "$relative"
    if ! path_exists "$backup"; then
      printf 'Backing up %s -> %s\n' "$source" "$backup"
      mv "$source" "$backup"
      move_count=$((move_count + 1))
      if [[ "$move_count" -eq 1 ]]; then
        maybe_fail after-first-move
      fi
    fi
    return 0
  fi

  [[ "$final" == "transform" ]] || return 0
  local original="$transaction_dir/backup/$relative"
  local transformed="$transaction_dir/work/config.transformed.yml"
  ensure_safe_backup_parent "$transaction_dir" "$relative"
  [[ -d "$transaction_dir/work" && ! -L "$transaction_dir/work" ]] ||
    fail "$transaction_dir/work is not a safe receipt directory"
  [[ ! -L "$original" && ! -L "$transformed" ]] || fail "the config receipt contains an unsafe symlink"
  if ! path_exists "$original"; then
    local backup_tmp
    backup_tmp="$(mktemp "$original.tmp.XXXXXX")"
    transient_files+=("$backup_tmp")
    cp -p "$source" "$backup_tmp"
    cmp -s "$source" "$backup_tmp" || fail "could not verify the config backup"
    mv "$backup_tmp" "$original"
  fi
  if [[ ! -f "$transformed" ]]; then
    local transformed_tmp
    transformed_tmp="$(mktemp "$transformed.tmp.XXXXXX")"
    transient_files+=("$transformed_tmp")
    render_transformed_config "$original" "$transformed_tmp"
    mv "$transformed_tmp" "$transformed"
    maybe_fail after-config-transform
  fi
  if cmp -s "$source" "$original"; then
    printf 'Trimming Nix-managed settings from %s\n' "$source"
    local live_tmp
    live_tmp="$(mktemp "$source.agent-tools-migration-v2.XXXXXX")"
    transient_files+=("$live_tmp")
    cp "$transformed" "$live_tmp"
    chmod 600 "$live_tmp"
    mv "$live_tmp" "$source"
    maybe_fail after-config-replace
  fi
}

create_pending_receipt() {
  check_for_orphaned_legacy_backup
  local staging="$state_root/.$migration_name.creating.$$"
  [[ ! -e "$staging" ]] || fail "$staging already exists"
  mkdir "$staging"
  transient_dirs+=("$staging")
  mkdir "$staging/backup" "$staging/work"
  chmod 700 "$staging" "$staging/backup" "$staging/work"
  discover_plan "$staging/receipt.tsv"
  mv "$staging" "$pending"
  transient_dirs=()
  maybe_fail after-receipt
}

prepare_migration() {
  if [[ "$dry_run" == "1" ]]; then
    if validate_terminal_state; then
      return 0
    fi
    if path_exists "$pending"; then
      validate_receipt "$pending"
      printf 'Would resume pending agent tools migration at %s\n' "$pending"
      return 0
    fi
    local dry_dir
    dry_dir="$(mktemp -d)"
    transient_dirs+=("$dry_dir")
    mkdir "$dry_dir/backup" "$dry_dir/work"
    chmod 700 "$dry_dir" "$dry_dir/backup" "$dry_dir/work"
    discover_plan "$dry_dir/receipt.tsv"
    printf 'Would prepare agent tools migration receipt with these actions:\n'
    sed -n '/^action/p' "$dry_dir/receipt.tsv"
    rm -rf "$dry_dir"
    transient_dirs=()
    return 0
  fi

  acquire_lock
  if validate_terminal_state; then
    return 0
  fi
  if path_exists "$pending"; then
    validate_receipt "$pending"
  else
    create_pending_receipt
  fi

  for_each_action "$pending" validate_pending_action
  move_count=0
  for_each_action "$pending" execute_pending_action
}

validate_final_action() {
  local transaction_dir="$1"
  local kind="$2"
  local final="$3"
  local relative="$4"
  local _detail="$5"
  local source="$HOME/$relative"
  local backup="$transaction_dir/backup/$relative"

  if [[ "$kind" == "move" ]]; then
    ensure_safe_backup_parent "$transaction_dir" "$relative"
    path_exists "$backup" || fail "the planned backup for $source is missing"
    [[ "$(source_identity "$backup")" == "$_detail" ]] ||
      fail "$backup changed while migration was pending"
    if [[ "$final" == "absent" ]]; then
      path_exists "$source" && fail "$source should remain retired"
      return 0
    fi
    local expected="$final_home_files/$relative"
    [[ -e "$expected" && -L "$source" ]] || fail "$source was not linked by Home Manager"
    [[ "$(readlink -e "$source")" == "$(readlink -e "$expected")" ]] ||
      fail "$source does not point to the selected Home Manager generation"
    return 0
  fi

  if [[ "$final" == "absent" ]]; then
    path_exists "$source" && fail "$source appeared while the migration was pending"
    return 0
  fi
  local original="$transaction_dir/backup/$relative"
  local transformed="$transaction_dir/work/config.transformed.yml"
  [[ -f "$original" && -f "$transformed" && -f "$source" ]] ||
    fail "$source or its migration copies are missing"
  [[ ! -L "$original" && ! -L "$transformed" && ! -L "$source" ]] ||
    fail "$source or its migration copies have an unsafe type"
  local original_digest
  original_digest="$(sha256sum "$original")"
  original_digest="${original_digest%% *}"
  [[ "$original_digest" == "$_detail" ]] || fail "$original no longer matches its receipt digest"
  validate_transformed_config "$transaction_dir" "$relative"
  cmp -s "$source" "$transformed" || fail "$source no longer matches the migrated config"
}

final_home_files=""
finalize_migration() {
  final_home_files="${1:-}"
  if [[ "$dry_run" == "1" ]]; then
    printf 'Would finalize a pending agent tools migration after Home Manager linking.\n'
    return 0
  fi
  [[ -n "$final_home_files" && -d "$final_home_files" ]] ||
    fail "finalize requires the selected Home Manager home-files directory"

  acquire_lock
  if validate_terminal_state; then
    return 0
  fi
  path_exists "$pending" || fail "no pending migration receipt exists"
  validate_receipt "$pending"
  for_each_action "$pending" validate_final_action
  maybe_fail before-finalize
  mv "$pending" "$complete"
}

command="${1:-prepare}"
if [[ $# -gt 0 ]]; then
  shift
fi
case "$command" in
  prepare)
    [[ $# -eq 0 ]] || fail "prepare does not accept arguments"
    prepare_migration
    ;;
  finalize)
    [[ $# -eq 1 ]] || fail "finalize requires one home-files directory"
    finalize_migration "$1"
    ;;
  *)
    fail "unknown command: $command"
    ;;
esac
