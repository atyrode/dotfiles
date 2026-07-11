#!/usr/bin/env bash
# shellcheck shell=bash
#
# Fresh-machine entry point for atyrode/dotfiles:
#
#   curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh \
#     | bash -s -- <registered-host> [install-args...]
#
# This fetched script only checks prerequisites and clones the repository;
# every mutation runs through the cloned, inspectable install.sh transaction.
# The body is function-wrapped so a truncated download defines functions but
# executes nothing.
set -euo pipefail

readonly origin_https='https://github.com/atyrode/dotfiles.git'
readonly origin_ssh='git@github.com:atyrode/dotfiles.git'

die() {
  printf 'get.sh: %s\n' "$*" >&2
  exit 1
}

main() {
  [[ $# -ge 1 && "$1" != -* ]] ||
    die 'usage: get.sh <registered-host> [install-args...]; hosts are declared in hosts/default.nix (for example alex-aarch64-darwin or alex-x86_64-linux)'
  local host="$1"
  shift

  command -v git >/dev/null ||
    die 'git is required first; install Xcode Command Line Tools (xcode-select --install) on macOS or your distribution git package on Linux'

  local dir="${DOTFILES_DIR:-$HOME/nix-dotfiles}"
  if [[ -e "$dir" ]]; then
    local existing
    existing="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
    [[ "$existing" == "$origin_https" || "$existing" == "$origin_ssh" ]] ||
      die "$dir exists and is not this repository; move it aside or set DOTFILES_DIR"
  else
    git clone "$origin_https" "$dir"
  fi

  # Under `curl | bash` stdin carries the script itself, so the bootstrap
  # confirmation must read from the terminal. Without one, only an explicit
  # --yes may stand in for the operator.
  local -a install_args=(apply --config "$host" "$@")
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
