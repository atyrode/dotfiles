# shellcheck shell=bash
#
# Primitives every other module leans on: exit, colour, the run log and step
# narration, capability and terminal predicates, and the small host-command
# helpers.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

die() {
  local code="$1"
  shift
  # Before the error itself, so the plan closes out in order: the step that
  # failed, the steps that never started, then why the run stopped.
  step_abandon_plan
  log_event "failed $code: $*"
  printf 'atyrode: %s\n' "$*" >&2
  [[ -z "$RUN_LOG" ]] || printf '  %s %s\n' "$(paint 2 'log:')" "$(paint 36 "$RUN_LOG")" >&2
  exit "$code"
}

# --- the run log --------------------------------------------------------------
#
# The terminal carries the story while an operator is watching; the log keeps
# the detail a later diagnosis needs, after the scrollback is gone and the
# question is "what did apply actually do to this machine, and when".
#
# Same contract as the bootstrap's log, because they narrate the same machine
# and an operator should not have to learn two: one file per invocation, UTC
# timestamps, mode 600, and logging that never fails a run. A machine too
# broken to write state is still allowed to try to converge itself.
RUN_LOG=""

start_run_log() { # command
  local dir

  dir="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/logs"
  [[ ! -L "$dir" ]] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null || true
  RUN_LOG="$dir/$(date -u +%Y%m%dT%H%M%SZ)-$1.log"
  if ! : >"$RUN_LOG" 2>/dev/null; then
    RUN_LOG=""
    return 0
  fi
  chmod 600 "$RUN_LOG" 2>/dev/null || true
  log_event "atyrode $1 on $(uname -s) as $(id -un 2>/dev/null || printf unknown)"
}

log_event() {
  [[ -n "$RUN_LOG" ]] || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$RUN_LOG" 2>/dev/null || true
}

# The shared narration library defaults to discarding its log; the CLI is the
# caller that keeps a durable transcript, so it points the hook at one.
narrate_log() { log_event "$@"; }

# The programs a machine declares live in the profiles activation writes, and
# nothing guarantees the caller's PATH names them. A bootstrap that has just
# activated still holds the PATH it started with, so everything downstream
# inspects the machine that existed a minute ago: `doctor tools` reports every
# managed program missing, the git family calls `gh` unavailable, and the babel
# ceremony -- which deliberately takes babel from the machine rather than
# carrying its closure into this CLI -- cannot find it. That is what turned a
# successful Darwin bootstrap into an unrecognised failure and an offer to
# reset a healthy Nix installation.
#
# Appended, never prepended. This CLI's own tools are prefixed onto PATH by its
# wrapper and must keep winning, and a directory already present keeps the
# position the caller gave it. The effect is strictly additive: programs that
# were invisible become findable, and nothing that already resolved moves.
adopt_activated_path() {
  local candidate user

  user="$(id -un 2>/dev/null || true)"
  for candidate in \
    /run/current-system/sw/bin \
    ${user:+"/etc/profiles/per-user/$user/bin"} \
    "${HOME:-}/.nix-profile/bin"; do
    [[ -d "$candidate" ]] || continue
    case ":$PATH:" in
      *":$candidate:"*) continue ;;
    esac
    PATH="$PATH:$candidate"
  done
  export PATH
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

# The clan CLI is installed by the security capability on clan machines and
# nowhere else, so a device that lacks it is told which machine it is rather
# than handed a bare "command not found". Announcements name the program that
# will run, so what an operator reads is what they can paste back.
clan_program() {
  local program=clan
  [[ "$test_hooks" != 1 || -z "${ATYRODE_CLAN:-}" ]] || program="$ATYRODE_CLAN"
  command -v "$program" 2>/dev/null ||
    die "$EX_UNAVAILABLE" "clan is not on PATH; it is installed by the security capability on clan machines"
}

# guard_production_mutation refuses to run a store-mutating command when a
# test-only tool-substitution override is present on a production binary. Those
# vars (including ATYRODE_BW, ATYRODE_CLAN, ATYRODE_AGE_KEYGEN, ATYRODE_AGE_PLUGIN_SE, ATYRODE_NIX, ATYRODE_SSH,
# ATYRODE_GIT, ATYRODE_NH, ATYRODE_SYSTEMD_RUN, and store/profile overrides)
# are honoured only under enableTestHooks;
# a production build silently ignores them, so a caller who sets them expecting stubs would instead
# drive the REAL nh / nix-store / nix-env against the live store. Aborting turns
# that silent, potentially destructive trap into a loud, safe stop. Scoped to the
# mutating verbs so read-only commands keep ignoring the vars outright (a hostile
# project environment can neither spoof nor block a plain `doctor`/`capabilities`).
# Running a tool that may be a stub under test. Visibility belongs to the call
# site rather than the program: `git rev-parse` only looks while `git clone`
# acts, and announcing from inside one wrapper would bury the handful of
# commands that change something under the dozen that ask a question. The
# `visible` form is a warning as much as a convenience -- what it is handed
# reaches the terminal and the run log, so it may carry the path to a secret
# but never a secret itself.
tool_exec() { # quiet|visible override_variable program argv...
  local visibility="$1" override="$2" program="$3"
  shift 3
  [[ "$test_hooks" != 1 || -z "${!override:-}" ]] || program="${!override}"
  if [[ "$visibility" == visible ]]; then
    run_visible "$program" "$@"
  else
    "$program" "$@"
  fi
}

guard_production_mutation() {
  [[ "$test_hooks" == 1 ]] && return 0
  local v
  for v in ATYRODE_AGE_KEYGEN ATYRODE_AGE_PLUGIN_SE ATYRODE_BW ATYRODE_CLAN ATYRODE_NH ATYRODE_NIX ATYRODE_NIX_STORE ATYRODE_NIX_ENV ATYRODE_GIT ATYRODE_SSH ATYRODE_SSH_KEYGEN ATYRODE_SSH_ADD ATYRODE_GH ATYRODE_GEN_PROFILE ATYRODE_WINGET ATYRODE_FETCH ATYRODE_SYSTEMCTL ATYRODE_SYSTEMD_RUN ATYRODE_JOURNALCTL ATYRODE_LAUNCHCTL; do
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
