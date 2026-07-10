#!/usr/bin/env bash
set -euo pipefail

# This script deliberately uses only Bash 3.2-era features and platform tools:
# it runs before Nix is guaranteed to exist, including on macOS.

migration_id="migration-v1-shell-entrypoints"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/migrations"
pending="$state_root/$migration_id.pending"
complete="$state_root/$migration_id.complete"

die() {
  printf 'bootstrap migration: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bootstrap-migrate.sh plan|prepare|commit|rollback|status

The migration backs up unmanaged ~/.zshrc and ~/.zshenv entrypoints before
activation. Receipts contain only versioned, home-relative logical paths.
EOF
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

is_managed_link() {
  local path="$1"
  local target

  [[ -L "$path" ]] || return 1
  target="$(readlink "$path")"
  case "$target" in
    /nix/store/*-home-manager-files/*) return 0 ;;
  esac
  return 1
}

path_kind() {
  if [[ -L "$1" ]]; then
    printf 'symlink\n'
  elif [[ -f "$1" ]]; then
    printf 'file\n'
  else
    die "$1 has an unsupported type; move it manually before continuing"
  fi
}

ensure_state_root() {
  local bootstrap_root="${state_root%/migrations}"
  local atyrode_root="${bootstrap_root%/bootstrap}"
  local directory

  for directory in "$atyrode_root" "$bootstrap_root" "$state_root"; do
    if path_exists "$directory"; then
      [[ -d "$directory" && ! -L "$directory" ]] ||
        die "$directory must be a real directory"
    else
      mkdir -p "$directory"
    fi
    chmod 700 "$directory"
  done
}

validate_state_root() {
  local bootstrap_root="${state_root%/migrations}"
  local atyrode_root="${bootstrap_root%/bootstrap}"
  local directory

  for directory in "$atyrode_root" "$bootstrap_root" "$state_root"; do
    if path_exists "$directory" && [[ ! -d "$directory" || -L "$directory" ]]; then
      die "$directory must be a real directory"
    fi
  done
}

validate_receipt() {
  local transaction="$1"
  local receipt="$transaction/receipt.tsv"
  local record relative kind extra
  local zshrc_count=0
  local zshenv_count=0
  local version_count=0

  [[ -d "$transaction" && ! -L "$transaction" ]] ||
    die "$transaction is not a safe migration transaction"
  [[ -f "$receipt" && ! -L "$receipt" ]] ||
    die "$transaction has no safe receipt"
  [[ -d "$transaction/backup" && ! -L "$transaction/backup" ]] ||
    die "$transaction has no safe backup directory"

  while IFS=$'\t' read -r record relative kind extra; do
    [[ -z "${extra:-}" ]] || die "migration receipt has unexpected fields"
    case "$record" in
      version)
        [[ "$relative" == 1 && -z "${kind:-}" ]] ||
          die "migration receipt has an unsupported version"
        version_count=$((version_count + 1))
        ;;
      move)
        case "$relative" in
          .zshrc) zshrc_count=$((zshrc_count + 1)) ;;
          .zshenv) zshenv_count=$((zshenv_count + 1)) ;;
          *) die "migration receipt contains an unsafe path: $relative" ;;
        esac
        case "$kind" in
          file|symlink) ;;
          *) die "migration receipt contains an unsafe path type" ;;
        esac
        ;;
      '') ;;
      *) die "migration receipt contains an unknown record" ;;
    esac
  done < "$receipt"

  [[ "$version_count" -eq 1 ]] || die "migration receipt has no unique version"
  [[ "$zshrc_count" -le 1 && "$zshenv_count" -le 1 ]] ||
    die "migration receipt contains duplicate paths"
}

validate_terminal_state() {
  local transaction

  validate_state_root
  for transaction in "$pending" "$complete"; do
    if path_exists "$transaction"; then
      [[ -d "$transaction" && ! -L "$transaction" ]] ||
        die "$transaction must be a real migration receipt directory"
    fi
  done
  if path_exists "$pending" && path_exists "$complete"; then
    die "both pending and complete receipts exist; preserve them and resolve the collision"
  fi
}

backup_name() {
  case "$1" in
    .zshrc) printf 'zshrc\n' ;;
    .zshenv) printf 'zshenv\n' ;;
    *) die "unsafe migration path: $1" ;;
  esac
}

validate_complete_backups() {
  local transaction="$1"
  local record relative kind extra backup name

  validate_receipt "$transaction"
  while IFS=$'\t' read -r record relative kind extra; do
    [[ "$record" == move ]] || continue
    name="$(backup_name "$relative")"
    backup="$transaction/backup/$name"
    case "$kind" in
      symlink) [[ -L "$backup" ]] || die "the recorded symlink backup for $relative is missing" ;;
      file) [[ -f "$backup" && ! -L "$backup" ]] || die "the recorded file backup for $relative is missing" ;;
    esac
  done < "$transaction/receipt.tsv"
}

print_plan_for_path() {
  local relative="$1"
  local source="$HOME/$relative"

  if path_exists "$source" && ! is_managed_link "$source"; then
    printf 'backup %s (%s) into the protected migration transaction\n' \
      "$relative" "$(path_kind "$source")"
  else
    printf 'leave %s unchanged (absent or already Home Manager-owned)\n' "$relative"
  fi
}

plan_migration() {
  validate_terminal_state
  if [[ -d "$complete" ]]; then
    validate_complete_backups "$complete"
    printf '%s is already complete; no migration changes are required\n' "$migration_id"
    return
  fi
  if [[ -d "$pending" ]]; then
    validate_receipt "$pending"
    printf 'resume %s from its pending receipt\n' "$migration_id"
    return
  fi

  print_plan_for_path .zshrc
  print_plan_for_path .zshenv
}

write_initial_receipt() {
  local transaction="$1"
  local receipt="$transaction/receipt.tsv"
  local relative source

  printf 'version\t1\n' > "$receipt"
  for relative in .zshrc .zshenv; do
    source="$HOME/$relative"
    if path_exists "$source" && ! is_managed_link "$source"; then
      printf 'move\t%s\t%s\n' "$relative" "$(path_kind "$source")" >> "$receipt"
    fi
  done
  chmod 600 "$receipt"
}

resume_prepare() {
  local record relative kind extra source backup name

  validate_receipt "$pending"
  while IFS=$'\t' read -r record relative kind extra; do
    [[ "$record" == move ]] || continue
    source="$HOME/$relative"
    name="$(backup_name "$relative")"
    backup="$pending/backup/$name"

    if path_exists "$backup"; then
      if ! path_exists "$source" || is_managed_link "$source"; then
        continue
      fi
      die "$relative and its migration backup both exist; preserve both and resolve the collision"
    fi
    path_exists "$source" ||
      die "$relative disappeared before its migration backup was created"
    [[ "$(path_kind "$source")" == "$kind" ]] ||
      die "$relative changed type before it could be backed up"
    mv "$source" "$backup"
    if [[ "${BOOTSTRAP_MIGRATION_FAILPOINT:-}" == "after-${relative#.}" ]]; then
      printf 'bootstrap migration: interrupted at test failpoint after-%s\n' "${relative#.}" >&2
      exit 75
    fi
  done < "$pending/receipt.tsv"
}

prepare_migration() {
  local creating

  ensure_state_root
  validate_terminal_state
  if [[ -e "$complete" || -L "$complete" ]]; then
    validate_complete_backups "$complete"
    printf '%s already complete\n' "$migration_id"
    return
  fi
  if [[ ! -d "$pending" ]]; then
    creating="$state_root/.$migration_id.creating.$$"
    [[ ! -e "$creating" && ! -L "$creating" ]] || die "temporary migration path already exists"
    mkdir "$creating"
    chmod 700 "$creating"
    mkdir "$creating/backup"
    chmod 700 "$creating/backup"
    write_initial_receipt "$creating"
    mv "$creating" "$pending"
  fi

  resume_prepare
  printf '%s prepared; original entrypoints are protected by the pending receipt\n' "$migration_id"
}

commit_migration() {
  local record relative kind extra source

  validate_terminal_state
  if [[ -d "$complete" ]]; then
    validate_complete_backups "$complete"
    printf '%s already complete\n' "$migration_id"
    return
  fi
  validate_receipt "$pending"
  while IFS=$'\t' read -r record relative kind extra; do
    [[ "$record" == move ]] || continue
    source="$HOME/$relative"
    is_managed_link "$source" ||
      die "$relative is not linked by Home Manager; refusing to complete the migration"
  done < "$pending/receipt.tsv"

  validate_complete_backups "$pending"

  mv "$pending" "$complete"
  printf '%s complete; backups remain in the protected receipt\n' "$migration_id"
}

rollback_transaction() {
  local transaction="$1"
  local record relative kind extra source backup name

  validate_receipt "$transaction"
  # Validate every restore before moving anything so a collision cannot cause a
  # half-rollback.
  while IFS=$'\t' read -r record relative kind extra; do
    [[ "$record" == move ]] || continue
    source="$HOME/$relative"
    name="$(backup_name "$relative")"
    backup="$transaction/backup/$name"
    if path_exists "$backup"; then
      if path_exists "$source" && ! is_managed_link "$source"; then
        die "$relative now contains user-owned data; refusing to overwrite it during rollback"
      fi
    else
      path_exists "$source" || die "$relative and its recorded backup are both missing"
      ! is_managed_link "$source" ||
        die "the recorded backup for $relative is missing after activation"
      [[ "$(path_kind "$source")" == "$kind" ]] ||
        die "$relative changed type before rollback"
    fi
  done < "$transaction/receipt.tsv"

  while IFS=$'\t' read -r record relative kind extra; do
    [[ "$record" == move ]] || continue
    source="$HOME/$relative"
    name="$(backup_name "$relative")"
    backup="$transaction/backup/$name"

    path_exists "$backup" || continue

    if path_exists "$source"; then
      rm "$source"
    fi
    mv "$backup" "$source"
  done < "$transaction/receipt.tsv"
}

rollback_migration() {
  local transaction=""
  local rolled_back

  ensure_state_root
  validate_terminal_state
  if [[ -d "$pending" ]]; then
    transaction="$pending"
  elif [[ -d "$complete" ]]; then
    transaction="$complete"
  else
    printf 'No bootstrap migration transaction needs rollback\n'
    return
  fi

  rollback_transaction "$transaction"
  rolled_back="$state_root/$migration_id.rolled-back"
  if [[ -e "$rolled_back" || -L "$rolled_back" ]]; then
    rolled_back="$rolled_back.$$"
  fi
  mv "$transaction" "$rolled_back"
  printf '%s rolled back; the relative-path receipt remains at %s\n' \
    "$migration_id" "${rolled_back#"$state_root/"}"
}

status_migration() {
  validate_terminal_state
  if [[ -d "$pending" ]]; then
    validate_receipt "$pending"
    printf 'pending\n'
  elif [[ -d "$complete" ]]; then
    validate_complete_backups "$complete"
    printf 'complete\n'
  else
    printf 'applicable\n'
  fi
}

case "${1:-}" in
  plan) plan_migration ;;
  prepare) prepare_migration ;;
  commit) commit_migration ;;
  rollback) rollback_migration ;;
  status) status_migration ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 64 ;;
esac
