#!/usr/bin/env bash
set -Eeuo pipefail

# The bootstrap intentionally stays compatible with Bash 3.2 and platform
# tools because it runs before the managed Nix environment exists.

readonly REPO_HTTPS_URL="https://github.com/atyrode/dotfiles.git"
readonly REPO_SSH_URL="git@github.com:atyrode/dotfiles.git"
readonly NIX_VERSION="2.34.7"
readonly BOOTSTRAP_SCHEMA="1"
readonly BOOTSTRAP_TEST_HOOKS=0

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMMAND="${1:-}"
if [[ -n "$COMMAND" ]]; then
  shift
fi

DOTFILES_DIR="${DOTFILES_DIR:-$SCRIPT_DIR}"
FLAKE_CONFIG="${FLAKE_CONFIG:-}"
ALLOW_DIRTY=0
ALLOW_NON_MAIN=0
UPDATE_SOURCE=0
ASSUME_YES=0
SYSTEM=""
NIX_URL=""
NIX_SHA256=""
TRANSACTION=""
SOURCE_CHANGED=0
ACTIVE_PHASE="bootstrap"

die() {
  printf 'bootstrap: %s\n' "$*" >&2
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  ./install.sh preflight [OPTIONS]
  ./install.sh plan [OPTIONS]
  ./install.sh apply [OPTIONS]
  ./install.sh verify [OPTIONS]
  ./install.sh rollback --yes [OPTIONS]

Options:
  --repo PATH          Use this existing checkout (default: script checkout).
  --config HOST        Select a registered host explicitly.
  --update             Fetch origin and fast-forward main before activation.
  --allow-dirty        Intentionally use a checkout with local changes.
  --allow-non-main     Intentionally use a branch or detached revision other than main.
  --yes                Confirm apply or rollback without an interactive prompt.
  -h, --help           Show this help.

No command defaults to mutation. Run `plan`, inspect it, then run `apply`.
EOF
}

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a path"
        DOTFILES_DIR="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || die "--config requires a registered host"
        FLAKE_CONFIG="$2"
        shift 2
        ;;
      --update)
        UPDATE_SOURCE=1
        shift
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      --allow-non-main)
        ALLOW_NON_MAIN=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

detect_system() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) printf 'aarch64-darwin\n' ;;
    Linux:arm64 | Linux:aarch64) printf 'aarch64-linux\n' ;;
    Linux:x86_64) printf 'x86_64-linux\n' ;;
    *) die "unsupported system: $(uname -s) $(uname -m)" ;;
  esac
}

select_nix_artifact() {
  case "$SYSTEM" in
    aarch64-darwin)
      NIX_SHA256="1e18301c4ea78c667f2753159156b5bdb899993720e8aa7bcca97e8312d3d6b"
      ;;
    aarch64-linux)
      NIX_SHA256="1cee64ae7a02330c6421924c28f597c41813f2214ff108622087d8056378b088"
      ;;
    x86_64-linux)
      NIX_SHA256="eafe5042404e818505e28c5ca3d0885f3ec45c31f955489a25bb38258f87560ef"
      ;;
    *) die "no pinned Nix artifact for $SYSTEM" ;;
  esac
  NIX_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-${SYSTEM}.tar.xz"
}

source_nix() {
  local profile=""

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_NIX_PROFILE_SCRIPT+x}" == x ]]; then
    profile="${BOOTSTRAP_NIX_PROFILE_SCRIPT:-}"
  elif [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    profile="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    profile="$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi
  if [[ -n "$profile" && -f "$profile" ]]; then
    set +u
    # shellcheck disable=SC1090 # The selected Nix profile script is runtime-dependent.
    . "$profile"
    set -u
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

canonicalize_repo() {
  [[ -d "$DOTFILES_DIR" ]] || die "repository directory does not exist: $DOTFILES_DIR"
  DOTFILES_DIR="$(CDPATH='' cd -- "$DOTFILES_DIR" && pwd -P)"
}

verify_origin() {
  local origin resolved

  origin="$(git -C "$DOTFILES_DIR" config --get remote.origin.url 2>/dev/null || true)"
  case "$origin" in
    "$REPO_HTTPS_URL" | "${REPO_HTTPS_URL%.git}" | "$REPO_SSH_URL" | ssh://git@github.com/atyrode/dotfiles.git)
      ;;
    '') die "checkout has no origin remote; expected $REPO_HTTPS_URL" ;;
    *) die "checkout origin is not atyrode/dotfiles; refusing to fetch or activate it" ;;
  esac
  resolved="$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || true)"
  case "$resolved" in
    "$REPO_HTTPS_URL" | "${REPO_HTTPS_URL%.git}" | "$REPO_SSH_URL" | ssh://git@github.com/atyrode/dotfiles.git)
      ;;
    *) die "origin resolves through Git configuration to an untrusted URL; remove url.*.insteadOf rewrites" ;;
  esac
}

verify_checkout() {
  local root branch status counts local_ahead remote_ahead

  [[ -f "$DOTFILES_DIR/flake.nix" ]] || die "not a dotfiles flake checkout: $DOTFILES_DIR"
  [[ -x "$DOTFILES_DIR/scripts/bootstrap-migrate.sh" ]] ||
    die "bootstrap migration script is missing or not executable"
  git -C "$DOTFILES_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "repository is not a Git checkout: $DOTFILES_DIR"
  git -C "$DOTFILES_DIR" ls-files --error-unmatch -- \
    flake.nix install.sh scripts/bootstrap-migrate.sh >/dev/null 2>&1 ||
    die "bootstrap entrypoints must be tracked by the verified repository"
  root="$(git -C "$DOTFILES_DIR" rev-parse --show-toplevel)"
  root="$(CDPATH='' cd -- "$root" && pwd -P)"
  [[ "$root" == "$DOTFILES_DIR" ]] || die "--repo must name the checkout root: $root"
  verify_origin

  if [[ "$UPDATE_SOURCE" -eq 1 && "$ALLOW_DIRTY" -eq 1 ]]; then
    die "--update cannot be combined with --allow-dirty"
  fi

  status="$(git -C "$DOTFILES_DIR" status --porcelain --untracked-files=normal)"
  if [[ -n "$status" && "$ALLOW_DIRTY" -ne 1 ]]; then
    die "checkout has staged, tracked, or untracked changes; use --allow-dirty only after reviewing them"
  fi

  branch="$(git -C "$DOTFILES_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$branch" != main && "$ALLOW_NON_MAIN" -ne 1 ]]; then
    if [[ -z "$branch" ]]; then
      die "checkout is detached; use --allow-non-main only for an intentionally reviewed revision"
    fi
    die "checkout is on $branch, not main; use --allow-non-main only after reviewing it"
  fi
  if [[ "$UPDATE_SOURCE" -eq 1 && "$branch" != main ]]; then
    die "--update is only supported on main"
  fi
  if [[ "$branch" == main ]]; then
    if git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/remotes/origin/main; then
      counts="$(git -C "$DOTFILES_DIR" rev-list --left-right --count HEAD...origin/main)"
      local_ahead="${counts%%[[:space:]]*}"
      remote_ahead="${counts##*[[:space:]]}"
      if [[ ("$local_ahead" != 0 || "$remote_ahead" != 0) && "$ALLOW_NON_MAIN" -ne 1 && "$UPDATE_SOURCE" -ne 1 ]]; then
        die "main differs from cached origin/main; use --update or --allow-non-main for a reviewed revision"
      fi
    elif [[ "$UPDATE_SOURCE" -ne 1 && "$ALLOW_NON_MAIN" -ne 1 ]]; then
      die "origin/main is unavailable; use --update or --allow-non-main for a reviewed revision"
    fi
  fi
}

bootstrap_state_root() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap"
}

preflight() {
  local pending

  command_exists git || die "git is required"
  command_exists tar || die "tar is required"
  command_exists mktemp || die "mktemp is required"
  canonicalize_repo
  verify_checkout

  SYSTEM="$(detect_system)"
  select_nix_artifact
  if [[ -z "$FLAKE_CONFIG" ]]; then
    die "--config HOST (or FLAKE_CONFIG) is required; bootstrap never guesses a machine profile"
  fi
  case "$FLAKE_CONFIG" in
    *[!A-Za-z0-9@._-]* | '') die "configuration contains unsupported characters" ;;
  esac

  source_nix
  if ! command_exists sha256sum && ! command_exists shasum; then
    die "sha256sum or shasum is required for verified receipts and Nix artifacts"
  fi
  if ! command_exists nix; then
    command_exists curl || die "curl is required to download the pinned Nix artifact"
  fi

  pending="$(bootstrap_state_root)/apply.pending"
  if [[ -e "$pending" || -L "$pending" ]]; then
    die "an interrupted bootstrap transaction exists; run ./install.sh rollback --yes before applying again"
  fi

  printf 'Preflight passed\n'
  printf '  system: %s\n' "$SYSTEM"
  printf '  configuration: %s\n' "$FLAKE_CONFIG"
  printf '  repository: %s\n' "$DOTFILES_DIR"
  printf '  revision: %s\n' "$(git -C "$DOTFILES_DIR" rev-parse --short=12 HEAD)"
}

print_plan() {
  local step=1

  printf '\nPlan\n'
  if [[ "$UPDATE_SOURCE" -eq 1 ]]; then
    printf '  %s. Fetch the verified origin and fast-forward main.\n' "$step"
    step=$((step + 1))
  fi
  if command_exists nix; then
    printf '  %s. Reuse the installed Nix command; do not reinstall it.\n' "$step"
  else
    printf '  %s. Download upstream Nix %s for %s and require SHA-256 %s.\n' \
      "$step" "$NIX_VERSION" "$SYSTEM" "$NIX_SHA256"
  fi
  step=$((step + 1))
  printf '  %s. Evaluate the registered host through the packaged atyrode CLI.\n' "$step"
  step=$((step + 1))
  printf '  %s. Prepare versioned shell-entrypoint migration backups:\n' "$step"
  "$DOTFILES_DIR/scripts/bootstrap-migrate.sh" plan | sed 's/^/     - /'
  step=$((step + 1))
  printf '  %s. Activate %s through atyrode/nh.\n' "$step" "$FLAKE_CONFIG"
  step=$((step + 1))
  printf '  %s. Verify host state and complete the migration and bootstrap receipts.\n' "$step"
  step=$((step + 1))
  if [[ "$SYSTEM" == *-darwin ]]; then
    printf '  %s. Verify nix-darwin configured the real account login shell.\n' "$step"
  else
    printf '  %s. Register and select the managed Zsh login shell with explicit privilege, then verify the account database.\n' "$step"
  fi
  printf '\nNo changes were made. apply will show this plan again before confirmation.\n'
}

confirm_action() {
  local prompt="$1"
  local answer

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return
  fi
  [[ -t 0 ]] || die "$prompt requires an interactive terminal or --yes"
  printf '%s [y/N] ' "$prompt" >&2
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES) ;;
    *) die "cancelled" ;;
  esac
}

ensure_safe_state_root() {
  local root="$1"
  local parent="${root%/*}"
  local transactions="$root/transactions"

  if [[ -e "$parent" || -L "$parent" ]]; then
    [[ -d "$parent" && ! -L "$parent" ]] || die "$parent must be a real directory"
  else
    mkdir -p "$parent"
  fi
  if [[ -e "$root" || -L "$root" ]]; then
    [[ -d "$root" && ! -L "$root" ]] || die "$root must be a real directory"
  else
    mkdir -p "$root"
  fi
  if [[ -e "$transactions" || -L "$transactions" ]]; then
    [[ -d "$transactions" && ! -L "$transactions" ]] ||
      die "$transactions must be a real directory"
  else
    mkdir "$transactions"
  fi
  chmod 700 "$root" "$transactions"
}

ensure_safe_login_shell_marker() {
  local marker

  marker="$(bootstrap_state_root)/login-shell.incomplete"
  if [[ -L "$marker" ]]; then
    die "unsafe login-shell prerequisite marker"
  elif [[ -f "$marker" || ! -e "$marker" ]]; then
    return
  else
    die "login-shell prerequisite marker has an unsupported type"
  fi
}

append_transaction() {
  [[ $# -eq 2 ]] || die "internal receipt error"
  printf '%s\t%s\n' "$1" "$2" >>"$TRANSACTION/receipt.tsv"
}

archive_abandoned_transactions() {
  local root="$1"
  local abandoned name target

  shopt -s nullglob
  for abandoned in "$root"/.apply.creating.*; do
    [[ -d "$abandoned" && ! -L "$abandoned" ]] ||
      die "unsafe abandoned bootstrap transaction: $abandoned"
    name="${abandoned##*/}"
    target="$root/transactions/${name#.}.abandoned"
    if [[ -e "$target" || -L "$target" ]]; then
      target="$target.$$"
    fi
    mv "$abandoned" "$target"
  done
  shopt -u nullglob
}

begin_transaction() {
  local root pending creating state_file state_status revision migration_sha installer_sha

  root="$(bootstrap_state_root)"
  state_file="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/dotfiles-config"
  if [[ -L "$state_file" ]]; then
    die "$state_file must not be a symlink"
  elif [[ -f "$state_file" ]]; then
    state_status=present
  elif [[ -e "$state_file" ]]; then
    die "$state_file has an unsupported type"
  else
    state_status=absent
  fi

  ensure_safe_state_root "$root"
  ensure_safe_login_shell_marker
  archive_abandoned_transactions "$root"
  pending="$root/apply.pending"
  [[ ! -e "$pending" && ! -L "$pending" ]] ||
    die "an interrupted bootstrap transaction already exists"
  creating="$(mktemp -d "$root/.apply.creating.XXXXXX")"
  [[ -d "$creating" && ! -L "$creating" ]] || die "could not create a safe transaction"
  TRANSACTION="$creating"
  chmod 700 "$TRANSACTION"
  mkdir "$TRANSACTION/backup" "$TRANSACTION/recovery"
  chmod 700 "$TRANSACTION/backup" "$TRANSACTION/recovery"
  cp "$DOTFILES_DIR/scripts/bootstrap-migrate.sh" "$TRANSACTION/recovery/bootstrap-migrate.sh"
  cp "${BASH_SOURCE[0]}" "$TRANSACTION/recovery/install.sh"
  chmod 700 "$TRANSACTION/recovery/bootstrap-migrate.sh" "$TRANSACTION/recovery/install.sh"
  migration_sha="$(sha256_file "$TRANSACTION/recovery/bootstrap-migrate.sh")"
  installer_sha="$(sha256_file "$TRANSACTION/recovery/install.sh")"
  revision="$(git -C "$DOTFILES_DIR" rev-parse HEAD)"
  {
    printf 'version\t%s\n' "$BOOTSTRAP_SCHEMA"
    printf 'system\t%s\n' "$SYSTEM"
    printf 'configuration\t%s\n' "$FLAKE_CONFIG"
    printf 'revision\t%s\n' "$revision"
    printf 'nix-version\t%s\n' "$NIX_VERSION"
    printf 'nix-sha256\t%s\n' "$NIX_SHA256"
    printf 'migration-sha256\t%s\n' "$migration_sha"
    printf 'installer-sha256\t%s\n' "$installer_sha"
    printf 'phase\tstarted\n'
  } >"$TRANSACTION/receipt.tsv"
  chmod 600 "$TRANSACTION/receipt.tsv"

  if [[ "$state_status" == present ]]; then
    cp "$state_file" "$TRANSACTION/backup/dotfiles-config"
    chmod 600 "$TRANSACTION/backup/dotfiles-config"
  fi
  append_transaction state-before "$state_status"
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_FAILPOINT:-}" == before-transaction-publish ]]; then
    printf 'bootstrap: interrupted at test failpoint before-transaction-publish\n' >&2
    exit 75
  fi
  mv "$TRANSACTION" "$pending"
  TRANSACTION="$pending"
}

transaction_value() {
  local key="$1"
  local record value extra found=""

  [[ -f "$TRANSACTION/receipt.tsv" && ! -L "$TRANSACTION/receipt.tsv" ]] ||
    die "unsafe bootstrap transaction receipt"
  while IFS=$'\t' read -r record value extra; do
    if [[ "$record" == "$key" ]]; then
      [[ -z "${extra:-}" && -z "$found" ]] || die "unsafe bootstrap receipt: duplicate or extra fields"
      found="$value"
    fi
  done <"$TRANSACTION/receipt.tsv"
  [[ -n "$found" ]] || die "unsafe bootstrap receipt: missing $key"
  printf '%s\n' "$found"
}

restore_previous_state() {
  local status config state_dir state_file backup current="" current_exists=0 temporary

  status="$(transaction_value state-before)"
  config="$(transaction_value configuration)"
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode"
  state_file="$state_dir/dotfiles-config"
  backup="$TRANSACTION/backup/dotfiles-config"
  if [[ -f "$state_file" && ! -L "$state_file" ]]; then
    current_exists=1
    current="$(cat "$state_file")"
  elif [[ -e "$state_file" || -L "$state_file" ]]; then
    die "$state_file changed to an unsafe type; preserve it and recover manually"
  fi

  case "$status" in
    present)
      [[ -f "$backup" && ! -L "$backup" ]] || die "previous host-state backup is missing"
      if [[ "$current_exists" -eq 1 && "$current" != "$config" ]] && ! cmp -s "$state_file" "$backup"; then
        die "host state changed after bootstrap began; refusing to overwrite it"
      fi
      if [[ -e "$state_dir" || -L "$state_dir" ]]; then
        [[ -d "$state_dir" && ! -L "$state_dir" ]] || die "$state_dir must be a real directory"
      else
        mkdir -p "$state_dir"
      fi
      temporary="$(mktemp "$state_dir/.dotfiles-config.restore.XXXXXX")"
      cp "$backup" "$temporary"
      chmod 600 "$temporary"
      mv "$temporary" "$state_file"
      ;;
    absent)
      if [[ "$current_exists" -eq 1 && "$current" != "$config" ]]; then
        die "host state was created by another process; refusing to remove it"
      fi
      if [[ -f "$state_file" && ! -L "$state_file" ]]; then
        rm "$state_file"
      fi
      ;;
    *) die "unsafe bootstrap receipt: invalid prior state" ;;
  esac
}

finish_transaction() {
  local outcome="$1"
  local root target stamp

  append_transaction outcome "$outcome"
  root="$(bootstrap_state_root)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$root/transactions/apply-v${BOOTSTRAP_SCHEMA}-${stamp}-$$.$outcome"
  if [[ -e "$target" || -L "$target" ]]; then
    target="$target.$$"
  fi
  mv "$TRANSACTION" "$target"
  TRANSACTION=""
  printf 'Bootstrap receipt: %s\n' "${target#"$root/"}"
}

migration_owned_by_transaction() {
  [[ -f "$TRANSACTION/migration-owned" && ! -L "$TRANSACTION/migration-owned" ]]
}

verify_recovery_script() {
  local name="$1"
  local key="$2"
  local path="$TRANSACTION/recovery/$name"
  local expected actual

  [[ -f "$path" && ! -L "$path" ]] || die "transaction recovery copy $name is missing or unsafe"
  expected="$(transaction_value "$key")"
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || die "transaction recovery copy $name failed verification"
}

migration_command() {
  verify_recovery_script bootstrap-migrate.sh migration-sha256
  bash "$TRANSACTION/recovery/bootstrap-migrate.sh" "$@"
}

rollback_current_transaction() {
  local migration_status

  if migration_owned_by_transaction; then
    migration_status="$(migration_command status)"
    case "$migration_status" in
      pending | complete) migration_command rollback ;;
      applicable) ;;
      *) die "migration recovery returned an unknown state" ;;
    esac
  fi
  restore_previous_state
}

fail_transaction() {
  local reason="$1"
  local recovery="$TRANSACTION/recovery/install.sh"

  trap - ERR INT TERM
  printf 'bootstrap: apply failed during %s\n' "$reason" >&2
  if [[ -n "$TRANSACTION" && -d "$TRANSACTION" ]]; then
    if BOOTSTRAP_RECOVERY_OUTCOME=failed BOOTSTRAP_FAILURE_REASON="$reason" \
      bash "$recovery" rollback --yes; then
      printf 'Original shell entrypoints and host-state receipt were restored.\n' >&2
    else
      printf 'Automatic recovery was incomplete. Preserve %s and run:\n' "$TRANSACTION" >&2
      printf '  bash %s rollback --yes\n' "$recovery" >&2
    fi
  fi
  printf 'Nix generations are not changed automatically during bootstrap recovery.\n' >&2
  exit 1
}

on_apply_error() {
  local status="$1"

  if [[ "${BASH_SUBSHELL:-0}" -gt 0 ]]; then
    return "$status"
  fi
  fail_transaction "$ACTIVE_PHASE (exit $status)"
}

update_checkout() {
  local counts local_ahead remote_ahead

  git -C "$DOTFILES_DIR" fetch --prune origin || return 1
  git -C "$DOTFILES_DIR" show-ref --verify --quiet refs/remotes/origin/main || return 1
  counts="$(git -C "$DOTFILES_DIR" rev-list --left-right --count HEAD...origin/main)" || return 1
  local_ahead="${counts%%[[:space:]]*}"
  remote_ahead="${counts##*[[:space:]]}"
  [[ "$local_ahead" == 0 ]] || {
    printf 'bootstrap: local main has commits not on origin/main; refusing to update\n' >&2
    return 1
  }
  if [[ "$remote_ahead" != 0 ]]; then
    git -C "$DOTFILES_DIR" merge --ff-only origin/main || return 1
    SOURCE_CHANGED=1
  fi
}

restart_after_source_update() {
  local args=(apply --repo "$DOTFILES_DIR" --config "$FLAKE_CONFIG")

  if [[ "$ASSUME_YES" -eq 1 ]]; then
    args+=(--yes)
  fi
  if [[ "$ALLOW_NON_MAIN" -eq 1 ]]; then
    args+=(--allow-non-main)
  fi
  exec bash "$DOTFILES_DIR/install.sh" "${args[@]}"
}

sha256_file() {
  local path="$1"

  if [[ "$SYSTEM" == *-darwin ]] && command_exists shasum; then
    shasum -a 256 "$path" | sed 's/[[:space:]].*$//'
  elif command_exists sha256sum; then
    sha256sum "$path" | sed 's/[[:space:]].*$//'
  else
    shasum -a 256 "$path" | sed 's/[[:space:]].*$//'
  fi
}

install_pinned_nix() {
  local temporary archive extracted actual

  temporary="$(mktemp -d "${TMPDIR:-/tmp}/atyrode-nix.XXXXXX")"
  archive="$temporary/nix.tar.xz"
  printf 'Downloading pinned upstream Nix %s from releases.nixos.org...\n' "$NIX_VERSION"
  if ! curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$NIX_URL"; then
    rm -rf "$temporary"
    return 1
  fi
  actual="$(sha256_file "$archive")"
  if [[ "$actual" != "$NIX_SHA256" ]]; then
    printf 'bootstrap: Nix artifact checksum mismatch (expected %s, received %s)\n' \
      "$NIX_SHA256" "$actual" >&2
    rm -rf "$temporary"
    return 1
  fi
  if ! tar -xf "$archive" -C "$temporary"; then
    rm -rf "$temporary"
    return 1
  fi
  extracted="$temporary/nix-${NIX_VERSION}-${SYSTEM}/install"
  if [[ ! -f "$extracted" || -L "$extracted" ]]; then
    printf 'bootstrap: verified Nix archive does not contain the expected installer\n' >&2
    rm -rf "$temporary"
    return 1
  fi
  append_transaction nix-source verified-upstream-artifact
  if ! sh "$extracted" --daemon; then
    rm -rf "$temporary"
    return 1
  fi
  rm -rf "$temporary"
  source_nix
  command_exists nix || return 1
  append_transaction nix-installed by-bootstrap
}

ensure_nix() {
  source_nix
  if command_exists nix; then
    append_transaction nix-source existing-installation
    return
  fi
  install_pinned_nix
}

enable_flakes_for_process() {
  local feature="extra-experimental-features = nix-command flakes"

  if [[ -n "${NIX_CONFIG:-}" ]]; then
    NIX_CONFIG="${NIX_CONFIG}
$feature"
  else
    NIX_CONFIG="$feature"
  fi
  export NIX_CONFIG
}

run_atyrode() {
  nix run "$DOTFILES_DIR#atyrode" -- "$@"
}

managed_activation_plan() {
  run_atyrode apply "$FLAKE_CONFIG" --repo "$DOTFILES_DIR" --plan
}

activate_configuration() {
  run_atyrode apply "$FLAKE_CONFIG" --repo "$DOTFILES_DIR" --restart-shell
}

verify_installation() {
  local state_file migration_status

  source_nix
  command_exists nix || die "Nix is not available"
  state_file="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/dotfiles-config"
  [[ -f "$state_file" && ! -L "$state_file" ]] || die "active host receipt is missing"
  [[ "$(cat "$state_file")" == "$FLAKE_CONFIG" ]] ||
    die "active host receipt does not match $FLAKE_CONFIG"
  run_atyrode doctor host "$FLAKE_CONFIG" >/dev/null
  if [[ -n "$TRANSACTION" ]]; then
    migration_status="$(migration_command status)"
  else
    migration_status="$(bash "$DOTFILES_DIR/scripts/bootstrap-migrate.sh" status)"
  fi
  [[ "$migration_status" == complete ]] || die "bootstrap migration is not complete"
  printf 'Verification passed for %s on %s\n' "$FLAKE_CONFIG" "$SYSTEM"
}

account_login_shell() {
  local user="$1"
  local fixture=""

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_ACCOUNT_SHELL_FILE:-}" ]]; then
    fixture="$BOOTSTRAP_ACCOUNT_SHELL_FILE"
  fi

  if [[ -n "$fixture" ]]; then
    [[ -f "$fixture" && ! -L "$fixture" ]] || return 1
    cat "$fixture"
  elif command_exists getent; then
    getent passwd "$user" 2>/dev/null | awk -F: 'NR == 1 { print $7 }'
  else
    return 1
  fi
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo -- "$@"
  else
    printf 'bootstrap: system prerequisite incomplete: sudo is required to configure the Linux login shell\n' >&2
    return 1
  fi
}

configure_linux_login_shell() {
  local user target shells_file current

  [[ "$SYSTEM" == *-linux ]] || return 0
  user="$(id -un)"
  target="$HOME/.nix-profile/bin/zsh"
  shells_file=/etc/shells
  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && -n "${BOOTSTRAP_SHELLS_FILE:-}" ]]; then
    shells_file="$BOOTSTRAP_SHELLS_FILE"
  fi
  [[ -x "$target" ]] || {
    printf 'bootstrap: system prerequisite incomplete: managed Zsh is not executable at %s\n' "$target" >&2
    return 1
  }
  [[ -f "$shells_file" && ! -L "$shells_file" ]] || {
    printf 'bootstrap: system prerequisite incomplete: %s must be a regular file\n' "$shells_file" >&2
    return 1
  }
  if ! grep -Fqx -- "$target" "$shells_file"; then
    # shellcheck disable=SC2016 # Positional parameters expand in the privileged shell.
    run_privileged sh -c \
      'grep -Fqx -- "$1" "$2" || printf "%s\n" "$1" >> "$2"' \
      sh "$target" "$shells_file" || {
      printf 'bootstrap: system prerequisite incomplete: could not register managed Zsh in %s\n' \
        "$shells_file" >&2
      return 1
    }
  fi
  current="$(account_login_shell "$user" || true)"
  if [[ "$current" != "$target" ]]; then
    command_exists chsh || {
      printf 'bootstrap: system prerequisite incomplete: chsh is unavailable\n' >&2
      return 1
    }
    run_privileged chsh -s "$target" "$user" || {
      printf 'bootstrap: system prerequisite incomplete: chsh could not update the account database\n' >&2
      return 1
    }
  fi
  current="$(account_login_shell "$user" || true)"
  [[ "$current" == "$target" ]] || {
    printf 'bootstrap: system prerequisite incomplete: account login shell remains %s\n' \
      "${current:-unknown}" >&2
    return 1
  }
}

mark_login_shell_incomplete() {
  local root temporary marker

  root="$(bootstrap_state_root)"
  marker="$root/login-shell.incomplete"
  ensure_safe_login_shell_marker
  temporary="$(mktemp "$root/.login-shell.incomplete.XXXXXX")"
  {
    printf 'version\t1\n'
    printf 'status\tincomplete\n'
    printf 'owner\tsystem-prerequisite\n'
  } >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$marker"
}

clear_login_shell_incomplete() {
  local marker

  marker="$(bootstrap_state_root)/login-shell.incomplete"
  ensure_safe_login_shell_marker
  if [[ -f "$marker" ]]; then
    rm "$marker"
  fi
}

verify_system_login_shell() {
  local diagnostics

  diagnostics="$(run_atyrode doctor system "$FLAKE_CONFIG" 2>/dev/null || true)"
  if ! grep -q '^login-shell: ok ' <<<"$diagnostics"; then
    printf 'bootstrap: system prerequisite incomplete: atyrode could not verify the real account login shell\n' >&2
    return 1
  fi
}

apply_configuration() {
  local migration_status

  preflight
  print_plan
  confirm_action "Apply this bootstrap plan?"

  if [[ "$UPDATE_SOURCE" -eq 1 ]]; then
    update_checkout || die "source update failed before any bootstrap transaction started"
    verify_checkout
    if [[ "$SOURCE_CHANGED" -eq 1 ]]; then
      restart_after_source_update
    fi
  fi

  begin_transaction
  trap 'on_apply_error $?' ERR
  trap 'fail_transaction "interrupt signal"' INT TERM

  ACTIVE_PHASE="Nix installation"
  append_transaction phase ensuring-nix
  ensure_nix
  enable_flakes_for_process

  ACTIVE_PHASE="managed host preflight"
  append_transaction phase managed-preflight
  managed_activation_plan

  ACTIVE_PHASE="migration state validation"
  migration_status="$(migration_command status)"
  if [[ "$migration_status" == complete ]]; then
    append_transaction migration preexisting-complete
  else
    : >"$TRANSACTION/migration-owned"
    chmod 600 "$TRANSACTION/migration-owned"
    append_transaction migration owned
  fi
  ACTIVE_PHASE="migration preparation"
  append_transaction phase preparing-migration
  migration_command prepare

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_FAILPOINT:-}" == after-migration-prepare ]]; then
    printf 'bootstrap: interrupted at test failpoint after-migration-prepare\n' >&2
    exit 75
  fi

  ACTIVE_PHASE="configuration activation"
  append_transaction phase activating
  activate_configuration
  ACTIVE_PHASE="migration completion"
  append_transaction phase committing-migration
  migration_command commit
  ACTIVE_PHASE="verification"
  append_transaction phase verifying
  verify_installation
  trap - ERR INT TERM
  mark_login_shell_incomplete
  finish_transaction complete

  if [[ "$BOOTSTRAP_TEST_HOOKS" == 1 && "${BOOTSTRAP_FAILPOINT:-}" == after-login-shell-receipt ]]; then
    printf 'bootstrap: interrupted at test failpoint after-login-shell-receipt\n' >&2
    exit 75
  fi

  if ! configure_linux_login_shell || ! verify_system_login_shell; then
    printf 'Home Manager activation completed, but the login-shell system prerequisite is incomplete.\n' >&2
    printf 'Fix the reported system boundary and run ./install.sh verify --config %s.\n' \
      "$FLAKE_CONFIG" >&2
    return 69
  fi
  clear_login_shell_incomplete

  printf '\nBootstrap complete. Open a new terminal or run: exec zsh -l\n'
}

rollback_interrupted() {
  local root current_sha expected_sha outcome reason

  root="$(bootstrap_state_root)"
  TRANSACTION="$root/apply.pending"
  if [[ ! -e "$TRANSACTION" && ! -L "$TRANSACTION" ]]; then
    printf 'No interrupted bootstrap transaction needs rollback.\n'
    return
  fi
  [[ -d "$TRANSACTION" && ! -L "$TRANSACTION" ]] ||
    die "interrupted transaction must be a real directory"
  [[ -f "$TRANSACTION/receipt.tsv" && ! -L "$TRANSACTION/receipt.tsv" ]] ||
    die "interrupted transaction has no safe receipt"
  verify_recovery_script install.sh installer-sha256
  expected_sha="$(transaction_value installer-sha256)"
  current_sha="$(sha256_file "${BASH_SOURCE[0]}")"
  if [[ "$current_sha" != "$expected_sha" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      exec bash "$TRANSACTION/recovery/install.sh" rollback --yes
    fi
    exec bash "$TRANSACTION/recovery/install.sh" rollback
  fi
  FLAKE_CONFIG="$(transaction_value configuration)"
  SYSTEM="$(transaction_value system)"
  confirm_action "Restore the interrupted bootstrap transaction?"
  rollback_current_transaction
  outcome="${BOOTSTRAP_RECOVERY_OUTCOME:-rolled-back}"
  case "$outcome" in
    failed | rolled-back) ;;
    *) die "invalid recovery outcome" ;;
  esac
  reason="${BOOTSTRAP_FAILURE_REASON:-operator-requested recovery}"
  append_transaction recovery "$reason"
  finish_transaction "$outcome"
  printf 'Interrupted bootstrap changes were rolled back.\n'
}

parse_options "$@"

case "$COMMAND" in
  preflight) preflight ;;
  plan)
    preflight
    print_plan
    ;;
  apply) apply_configuration ;;
  verify)
    preflight
    enable_flakes_for_process
    verify_installation
    verify_system_login_shell || die "login-shell system prerequisite is incomplete"
    clear_login_shell_incomplete
    ;;
  rollback) rollback_interrupted ;;
  -h | --help | help) usage ;;
  '')
    usage >&2
    exit 64
    ;;
  *)
    usage >&2
    die "unknown phase: $COMMAND"
    ;;
esac
