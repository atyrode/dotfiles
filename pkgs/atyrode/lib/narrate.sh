# The voice every managed program on this machine speaks in.
#
# `atyrode apply` narrates carefully -- the argv of anything that acts, a
# reason, a verdict -- and then hands the terminal to a ceremony that dumps
# plain white text and prompts for a password with nothing to say where the
# prompt came from. The operator does not experience two programs; they
# experience one machine that goes quiet halfway through. So the narration
# lives here rather than inside the CLI, and the ceremonies source it.
#
# It carries no state of its own beyond the current step. Programs that keep a
# durable transcript replace narrate_log; the ones that do not get a no-op and
# behave identically otherwise.
#
# shellcheck shell=bash

# Replaced by callers that own a run log. Defined as a no-op so a standalone
# script narrates correctly without inventing a logging story it does not have.
narrate_log() { # message
  :
}

# Forced on or off from the test harness, which has neither a terminal nor any
# use for escape codes in an assertion.
_narrate_use_color() {
  if [[ -n "${_ATYRODE_TEST_COLOR:-}" ]]; then
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
  if _narrate_use_color; then printf '\033[%sm%s\033[0m' "$code" "$*"; else printf '%s' "$*"; fi
}

# Whether we can hold a yes/no dialogue with a human: both ends of the pipe are
# a terminal. The override forces it on so confirm gates stay exercisable from a
# harness that has no tty.
interactive() {
  [[ -n "${_ATYRODE_TEST_TTY:-}" ]] && return 0
  [[ -t 0 && -t 1 ]]
}

# Whether the progress channel is a live terminal, so a collector can choose
# between an animated line and streaming its raw output.
stderr_is_tty() {
  [[ -n "${_ATYRODE_TEST_TTY:-}" ]] && return 0
  [[ -t 2 ]]
}

# Anything that changes this machine or takes real time is printed before it
# runs, shell-quoted so what is shown can be pasted back. Read-only probing
# stays silent: an operator wants to see the four commands that act, not the
# forty that look.
show_command() {
  local rendered
  rendered="$(render_argv "$@")"
  narrate_log "run: $rendered"
  printf '%s\n' "$(paint 2 "$STEP_INDENT\$ $rendered")" >&2
}

render_argv() {
  local rendered="" part
  for part in "$@"; do
    rendered="$rendered${rendered:+ }$(printf '%q' "$part")"
  done
  printf '%s' "$rendered"
}

# A command whose shape is shell syntax -- a pipe, a redirection -- is still
# one command to the operator, and what is announced must paste back as it
# stands. The caller composes the line from render_argv pieces so the pipe or
# the `>` stays itself instead of becoming a quoted character.
show_rendered() { # rendered-shell-line
  narrate_log "run: $1"
  printf '%s\n' "$(paint 2 "$STEP_INDENT\$ $1")" >&2
}

run_visible() {
  local status=0
  show_command "$@"
  "$@" || status=$?
  [[ "$status" -eq 0 ]] || narrate_log "exit $status: $1"
  return "$status"
}

# A line in this program's own voice: what it found, what it wrote, what it is
# about to ask of the operator. Distinct from a command announcement, which is
# somebody else's program starting.
say() { # text
  narrate_log "$1"
  printf '%s%s\n' "$STEP_INDENT" "$1" >&2
}

# A refusal, in the same voice, naming the program that refused. Callers that
# exit afterwards do so themselves: what to do about a refusal belongs to
# whoever knows the surrounding transaction.
refuse() { # program text
  narrate_log "failed: $2"
  printf '%s %s\n' "$(paint '1;31' "$1:")" "$2" >&2
}

# Ask a yes/no question; default no, and no on a non-interactive stream.
#
# A terminal echoes the operator's Enter and ends the prompt line for us. A
# piped answer echoes nothing, so without this the next thing printed -- the
# command the answer just authorised -- lands on the prompt's own line.
confirm() { # question
  local reply
  interactive || return 1
  printf '%s %s %s ' "$(paint 1 "${NARRATE_NAME:-atyrode}:")" \
    "$(paint 1 "$1")" "$(paint 2 '[y/N]')" >&2
  read -r reply || {
    [[ -t 0 ]] || printf '\n' >&2
    return 1
  }
  [[ -t 0 ]] || printf '\n' >&2
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# --- steps --------------------------------------------------------------------
#
# Work an operator waits on is a step: it announces itself, may state the
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
    narrate_log "plan $index/$STEP_TOTAL: $label"
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
    narrate_log "step $index/$STEP_TOTAL not attempted: ${STEP_PLAN[index - 1]}"
  done
  STEP_INDEX="$STEP_TOTAL"
}

step_begin() { # label
  STEP_INDEX=$((STEP_INDEX + 1))
  _step_started="$(date +%s)"
  STEP_INDENT='  '
  printf '\n%s %s\n' \
    "$(paint '1;36' "$STEP_INDEX/$STEP_TOTAL")" "$(paint 1 "$1")" >&2
  narrate_log "step $STEP_INDEX/$STEP_TOTAL: $1"
}

# Why this step exists, in the vocabulary of the thing that decided it: a
# declaration this machine has to match, or a diagnosis that was just made.
# Printed only where the answer is not already in the label.
step_why() { # text
  printf '  %s %s\n' "$(paint 2 'why')" "$1" >&2
  narrate_log "  why: $1"
}

# A fact the step established or a file it wrote -- the detail that makes the
# verdict checkable rather than merely reassuring.
step_detail() { # text
  printf '  %s\n' "$(paint 2 "$1")" >&2
  narrate_log "  $1"
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
  narrate_log "  ok${detail:+ $detail}"
  _step_end "$(paint '1;32' 'ok')" "$detail"
}

step_skip() { # reason
  narrate_log "  skipped $1"
  _step_end "$(paint '1;33' 'skipped')" "$1"
}

step_fail() { # detail
  narrate_log "  failed $1"
  _step_end "$(paint '1;31' 'failed')" "$1"
}
