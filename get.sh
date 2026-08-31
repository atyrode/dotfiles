#!/usr/bin/env bash
# shellcheck shell=bash
#
# Fresh-machine entry point for atyrode/dotfiles:
#
#   curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh \
#     | bash -s -- [registered-host] [install-args...]
#
# Without a host argument it lists the registry's presets for this machine's
# system and prompts for a choice. This fetched script only checks
# prerequisites, clones the repository, and selects a configuration; every
# mutation runs through the cloned, inspectable install.sh transaction. The
# body is function-wrapped so a truncated download defines functions but
# executes nothing.
set -euo pipefail

readonly origin_https='https://github.com/atyrode/dotfiles.git'
readonly origin_ssh='git@github.com:atyrode/dotfiles.git'

die() {
  printf 'get.sh: %s\n' "$*" >&2
  exit 1
}

pick_host() {
  local dir="$1" inventory="$1/inventory/hosts.tsv" system
  [[ -r "$inventory" ]] || die 'host inventory missing from the clone; pass a registered host explicitly'
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) system='aarch64-darwin' ;;
    Linux:arm64 | Linux:aarch64) system='aarch64-linux' ;;
    Linux:x86_64) system='x86_64-linux' ;;
    *) die "unsupported platform: $(uname -s) $(uname -m)" ;;
  esac

  local -a ids=() lines=()
  local id host_system capabilities description
  while IFS=$'\t' read -r id host_system capabilities description; do
    [[ "$host_system" == "$system" ]] || continue
    ids+=("$id")
    lines+=("$id - $description [$capabilities]")
  done <"$inventory"
  [[ ${#ids[@]} -gt 0 ]] || die "no registered configuration targets $system"

  if ! { : </dev/tty; } 2>/dev/null; then
    die "no interactive terminal to choose a configuration; pass one of: ${ids[*]}"
  fi
  printf 'Registered %s configurations:\n' "$system" >&2
  local i
  for i in "${!ids[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${lines[$i]}" >&2
  done
  local choice
  read -r -p "Select a configuration [1-${#ids[@]}]: " choice </dev/tty
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#ids[@]})); then
    die "invalid selection: $choice"
  fi
  printf '%s\n' "${ids[$((choice - 1))]}"
}

require_registered_host() {
  local dir="$1" requested="$2" inventory="$1/inventory/hosts.tsv"
  [[ -r "$inventory" ]] || die 'host inventory missing from the clone'

  local -a ids=()
  local id host_system capabilities description
  while IFS=$'\t' read -r id host_system capabilities description; do
    ids+=("$id")
    [[ "$id" == "$requested" ]] && return
  done <"$inventory"

  local quoted
  printf -v quoted '%q' "$requested"
  die "unknown configuration $quoted; choose one of: ${ids[*]}"
}

# Explicit source-policy flags are reviewed operator decisions about which
# revision to activate; this entry point must never silently add another.
source_policy_given() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --update | --allow-dirty | --allow-non-main) return 0 ;;
    esac
  done
  return 1
}

main() {
  local host=""
  if [[ $# -ge 1 && "$1" != -* ]]; then
    host="$1"
    shift
  fi

  command -v git >/dev/null ||
    die 'git is required first; install Xcode Command Line Tools (xcode-select --install) on macOS or your distribution git package on Linux'

  local dir="${DOTFILES_DIR:-$HOME/nix-dotfiles}"
  local reused=0
  if [[ -e "$dir" ]]; then
    local existing
    existing="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
    [[ "$existing" == "$origin_https" || "$existing" == "$origin_ssh" ]] ||
      die "$dir exists and is not this repository; move it aside or set DOTFILES_DIR"
    reused=1
  else
    git clone "$origin_https" "$dir"
  fi

  [[ -n "$host" ]] || host="$(pick_host "$dir")"
  require_registered_host "$dir" "$host"

  # A reused checkout is not a fresh one: its install.sh, host inventory, and
  # revision can all be stale, and a stale install.sh would then decide what
  # this fetched script means. The entry point means "install current upstream
  # main", so route reuse through install.sh's reviewed --update path, which
  # fast-forwards and re-enters the updated script.
  local -a install_args=(apply --config "$host")
  if [[ "$reused" == 1 ]] && ! source_policy_given "$@"; then
    install_args+=(--update)
    printf 'get.sh: reusing the checkout at %s; it will be updated to origin/main before activation (set DOTFILES_DIR to bootstrap elsewhere)\n' \
      "$dir" >&2
  fi
  install_args+=("$@")

  # Under `curl | bash` stdin carries the script itself, so the bootstrap
  # confirmation must read from the terminal. Without one, only an explicit
  # --yes may stand in for the operator.
  if { : </dev/tty; } 2>/dev/null; then
    exec "$dir/install.sh" "${install_args[@]}" </dev/tty
  fi
  local arg
  for arg in "$@"; do
    if [[ "$arg" == --yes ]]; then
      exec "$dir/install.sh" "${install_args[@]}" </dev/null
    fi
  done
  die 'no interactive terminal for the confirmation prompt; append --yes to accept the printed plan'
}

main "$@"
