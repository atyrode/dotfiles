# shellcheck shell=bash
#
# Primitives every other module leans on: exit, colour, capability and
# terminal predicates, and the small host-command helpers.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

die() {
  local code="$1"
  shift
  printf 'atyrode: %s\n' "$*" >&2
  exit "$code"
}

is_wsl() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_WSL:-}" ]]; then
    [[ "$_ATYRODE_TEST_WSL" == 1 ]]
    return
  fi
  [[ -n "${WSL_INTEROP:-}" ]] ||
    { [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease; }
}

expand_home_path() {
  local path="$1"
  if [[ "$path" == \~/* ]]; then
    printf '%s/%s\n' "$HOME" "${path:2}"
  else
    printf '%s\n' "$path"
  fi
}

has_capability() {
  local data="$1" capability="$2"
  jq -e --arg capability "$capability" '.capabilities | index($capability)' <<<"$data" >/dev/null
}

word_in_list() {
  local needle="$1" words="$2"
  case " $words " in
    *" $needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

# The public launcher for this CLI. makeWrapper runs the payload as
# .atyrode-wrapped, so a child re-entered through $0 would inherit the caller's
# PATH instead of the package's pinned one. Every re-entry - the manager-owned
# apply worker, an accepted provisioning offer - goes through the wrapper.
atyrode_self() {
  local self
  self="$(readlink -f "$0")"
  [[ "${self##*/}" != .atyrode-wrapped ]] || self="${self%/*}/atyrode"
  [[ -x "$self" ]] || return 1
  printf '%s\n' "$self"
}

# interactive reports whether we can hold a yes/no dialogue with a human (both
# ends of the pipe are a terminal). A test override forces it on so the confirm
# gates are exercisable from the non-tty check harness.
interactive() {
  [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_TTY:-}" ]] && return 0
  [[ -t 0 && -t 1 ]]
}

# stderr_is_tty reports whether the progress channel (stderr) is a live terminal,
# so the collector can choose between the animated progress line and streaming its
# raw output. Same test override as interactive() drives the live path in checks.
stderr_is_tty() {
  [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_TTY:-}" ]] && return 0
  [[ -t 2 ]]
}

# _use_color decides whether to emit ANSI colour: only when stderr (where all the
# human-facing chatter goes) is a terminal and the environment permits it —
# NO_COLOR honoured, TERM=dumb excluded — so pipes, redirects, and the --json
# stream stay plain. A test override forces the decision either way.
_use_color() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_COLOR:-}" ]]; then
    [[ "$_ATYRODE_TEST_COLOR" == 1 ]]
    return
  fi
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]
}

# paint wraps text in an SGR code when colour is on, else prints it bare, so every
# colourised message degrades cleanly to plain text (e.g. paint '1;36' "text").
paint() {
  local code="$1"
  shift
  if _use_color; then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}

# Ask a yes/no question; default no, and no on a non-interactive stream.
confirm() {
  local reply
  interactive || return 1
  printf 'atyrode: %s %s ' "$(paint 1 "$1")" "$(paint 2 '[y/N]')" >&2
  read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# effective_uid reports the caller's EUID so clean can tell whether it is able to
# reap the daemon-owned auto GC roots: only root can unlink them, and atyrode
# never self-elevates (see the elevation note in cmd_rollback) — a non-root clean
# instead points at `sudo atyrode clean`. A test override exercises the privileged
# branch without actually running as root.
effective_uid() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_EUID:-}" ]]; then
    printf '%s' "$_ATYRODE_TEST_EUID"
    return
  fi
  printf '%s' "${EUID:-$(id -u)}"
}

# nix_store_path resolves nix-store to an absolute path so the reap hint names a
# command that survives elevation. On a non-NixOS host root's sudoers secure_path
# excludes every Nix profile directory, so a bare `nix-store` (like `atyrode` or
# `nh`) is not found under elevation — but an absolute path is executed directly,
# bypassing the PATH search entirely. Honours the test override.
nix_store_path() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_NIX_STORE:-}" ]]; then
    printf '%s' "$ATYRODE_NIX_STORE"
    return
  fi
  command -v nix-store 2>/dev/null || printf 'nix-store'
}

# nix_env runs nix-env, honouring an ATYRODE_NIX_ENV override under test hooks
# (mirrors ATYRODE_NH / ATYRODE_NIX_STORE) so generation reads are stubbable.
nix_env() {
  local cmd=nix-env
  [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX_ENV:-}" ]] || cmd="$ATYRODE_NIX_ENV"
  "$cmd" "$@"
}

# guard_production_mutation refuses to run a store-mutating command when a
# test-only tool-substitution override is present on a production binary. Those
# vars (including ATYRODE_BW, ATYRODE_AGE_KEYGEN, ATYRODE_NIX, ATYRODE_SSH,
# ATYRODE_GIT, ATYRODE_NH, ATYRODE_SYSTEMD_RUN, and store/profile overrides)
# are honoured only under enableTestHooks;
# a production build silently ignores them, so a caller who sets them expecting stubs would instead
# drive the REAL nh / nix-store / nix-env against the live store. Aborting turns
# that silent, potentially destructive trap into a loud, safe stop. Scoped to the
# mutating verbs so read-only commands keep ignoring the vars outright (a hostile
# project environment can neither spoof nor block a plain `doctor`/`capabilities`).
guard_production_mutation() {
  [[ "$test_hooks" == 1 ]] && return 0
  local v
  for v in ATYRODE_AGE_KEYGEN ATYRODE_BW ATYRODE_NH ATYRODE_NIX ATYRODE_NIX_STORE ATYRODE_NIX_ENV ATYRODE_GIT ATYRODE_SSH ATYRODE_SSH_KEYGEN ATYRODE_SSH_ADD ATYRODE_GH ATYRODE_GEN_PROFILE ATYRODE_WINGET ATYRODE_FETCH ATYRODE_SYSTEMCTL ATYRODE_SYSTEMD_RUN ATYRODE_JOURNALCTL ATYRODE_LAUNCHCTL; do
    [[ -z "${!v:-}" ]] || die "$EX_USAGE" \
      "$1 refuses to run: $v is set but a production build ignores it, so this would drive the real tool against the live store — unset $v, or use a build with enableTestHooks = true for stubs"
  done
}

# Optional runtime-host command (unlike the winget lookup this must not die: a
# machine without systemd still gets a truthful status report).
optional_host_command() {
  local variable="$1" default="$2" candidate
  candidate="$default"
  if [[ "$test_hooks" == 1 && -n "${!variable:-}" ]]; then
    candidate="${!variable}"
  fi
  command -v "$candidate" 2>/dev/null
}
