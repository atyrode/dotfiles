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

# Anything that changes this machine or takes real time is printed before it
# runs, shell-quoted so what is shown can be pasted back. Read-only probing
# stays silent: an operator wants to see the four commands that act, not the
# forty that look.
show_command() {
  local rendered="" part

  for part in "$@"; do
    rendered="$rendered${rendered:+ }$(printf '%q' "$part")"
  done
  log_event "run: $rendered"
  printf '%s\n' "$(paint 2 "$STEP_INDENT\$ $rendered")" >&2
}

run_visible() {
  local status=0
  show_command "$@"
  "$@" || status=$?
  [[ "$status" -eq 0 ]] || log_event "exit $status: $1"
  return "$status"
}

# --- steps --------------------------------------------------------------------
#
# A command an operator can read is half of it. The other half is why it ran
# and whether it worked: a transcript of argv with no outcomes leaves someone
# scrolling back to guess which of six things failed, and a machine that says
# nothing while converging looks identical to one that is stuck.
#
# So work an operator waits on is a step: it announces itself, may state the
# declaration or diagnosis that makes it necessary, and always closes with a
# verdict. Steps do not nest -- a nested one is a step of its own or a detail
# line of this one -- so the indent below is set on entry and cleared on the
# verdict rather than kept on a stack. Outside a step it is empty, so a bare
# `atyrode provision babel` still prints its commands flush left.
STEP_INDENT=''
STEP_TOTAL=0
STEP_INDEX=0
STEP_PLAN=()
_step_started=0

# The plan is the same list the steps then walk, printed up front so an
# operator knows the shape of the run before the first build scrolls past.
# The labels are kept, not just the count, because an aborted run still owes a
# verdict on the steps it promised.
plan_steps() { # label...
  local index=0 label

  STEP_TOTAL=$#
  STEP_INDEX=0
  STEP_PLAN=("$@")
  printf '\n%s\n' "$(paint 1 'Plan')" >&2
  for label in "$@"; do
    index=$((index + 1))
    printf '  %d. %s\n' "$index" "$label" >&2
    log_event "plan $index/$STEP_TOTAL: $label"
  done
}

# A plan is a promise about what this run will do, so an abort owes the
# operator the rest of it. Without this a failure at step 1 of 4 leaves steps 2
# through 4 simply missing from the terminal, which reads as though they ran
# and said nothing rather than never having started.
step_abandon_plan() {
  local index

  [[ "$STEP_TOTAL" -gt 0 && "$STEP_INDEX" -lt "$STEP_TOTAL" ]] || return 0
  for ((index = STEP_INDEX + 1; index <= STEP_TOTAL; index++)); do
    printf '\n%s %s\n  %s\n' \
      "$(paint '1;36' "$index/$STEP_TOTAL")" "$(paint 1 "${STEP_PLAN[index - 1]}")" \
      "$(paint 2 'not attempted')" >&2
    log_event "step $index/$STEP_TOTAL not attempted: ${STEP_PLAN[index - 1]}"
  done
  STEP_INDEX="$STEP_TOTAL"
}

step_begin() { # label
  STEP_INDEX=$((STEP_INDEX + 1))
  _step_started="$(date +%s)"
  STEP_INDENT='  '
  printf '\n%s %s\n' \
    "$(paint '1;36' "$STEP_INDEX/$STEP_TOTAL")" "$(paint 1 "$1")" >&2
  log_event "step $STEP_INDEX/$STEP_TOTAL: $1"
}

# Why this step exists, in the vocabulary of the thing that decided it: a
# declaration this machine has to match, or a diagnosis that was just made.
# Printed only where the answer is not already in the label.
step_why() { # text
  printf '  %s %s\n' "$(paint 2 'why')" "$1" >&2
  log_event "  why: $1"
}

# A fact the step established or a file it wrote -- the detail that makes the
# verdict checkable rather than merely reassuring.
step_detail() { # text
  printf '  %s\n' "$(paint 2 "$1")" >&2
  log_event "  $1"
}

# Elapsed time is a diagnostic, not a stopwatch: printed only once a step took
# long enough that an operator wondered, so the fast ones stay quiet.
_step_elapsed() {
  local seconds
  [[ "$_step_started" != 0 ]] || return 0
  seconds=$(($(date +%s) - _step_started))
  ((seconds >= 2)) || return 0
  printf ' %s' "$(paint 2 "${seconds}s")"
}

_step_end() { # painted-verdict detail
  printf '  %s%s%s\n' "$1" "${2:+ $2}" "$(_step_elapsed)" >&2
  STEP_INDENT=''
  _step_started=0
}

# The detail is optional: a step whose label already says everything closes on
# a bare `ok` rather than restating itself.
step_ok() { # [detail]
  local detail="${1:-}"
  log_event "  ok${detail:+ $detail}"
  _step_end "$(paint '1;32' 'ok')" "$detail"
}

# Not every step has work to do, and a step that had none must say so rather
# than leaving a silence an operator has to interpret.
step_skip() { # reason
  log_event "  skip $1"
  _step_end "$(paint 2 'skip')" "$(paint 2 "$1")"
}

# A step can fail without ending the apply -- activation has already happened
# and the remaining surfaces still deserve their turn -- so this reports and
# returns rather than exiting. The caller decides what a failure is worth.
step_fail() { # detail
  log_event "  failed $1"
  _step_end "$(paint '1;31' 'failed')" "$1"
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
#
# A terminal echoes the operator's Enter and ends the prompt line for us. A
# piped answer echoes nothing, so without this the next thing printed -- the
# command the answer just authorised -- lands on the prompt's own line.
confirm() {
  local reply
  interactive || return 1
  printf 'atyrode: %s %s ' "$(paint 1 "$1")" "$(paint 2 '[y/N]')" >&2
  read -r reply || {
    [[ -t 0 ]] || printf '\n' >&2
    return 1
  }
  [[ -t 0 ]] || printf '\n' >&2
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
