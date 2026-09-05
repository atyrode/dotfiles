# shellcheck shell=bash
#
# The converge floor (ADR 0008, "The flow", step 3): a machine left alone
# still ends up on green main. `atyrode apply --unattended` is what a timer
# runs; it never asks, never builds what CI has not, and never touches a
# checkout. Every run ends in one receipt that doctor and the login shell read
# back, so a machine that held says why without anyone re-running anything.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

converge_receipt_file() {
  printf '%s/atyrode/converge.json' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# The revision this machine runs is the one embedded in the CLI activation
# installed -- except across the launcher handoff, where the CLI that finishes
# the run is main's own and would otherwise report itself as already current.
# The launcher names what was running before it handed over.
converge_running_revision() {
  printf '%s' "${ATYRODE_CONVERGE_RUNNING:-$embedded_revision}"
}

# outcome is one of:
#   current    the running generation already is the published revision
#   converged  this run activated the published revision
#   held       the revision is newer, and a precondition kept this run from
#              activating it; reason says which, remediation what clears it
#   failed     the run stopped on an error; the log has the detail
# The receipt is the only durable trace an unattended run leaves that a human
# reads, so it names both revisions in full: which one runs and which one main
# had at the time.
converge_record() { # outcome host target reason remediation
  local file directory temporary
  file="$(converge_receipt_file)"
  directory="$(dirname "$file")"
  mkdir -p "$directory" 2>/dev/null || return 0
  temporary="$(mktemp "$directory/.converge.XXXXXX")" || return 0
  jq -nc --arg outcome "$1" --arg host "$2" --arg target "$3" --arg reason "$4" \
    --arg remediation "$5" --arg running "$(converge_running_revision)" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg log "${RUN_LOG:-}" \
    '{schemaVersion:1,command:"apply --unattended",at:$at,host:$host,outcome:$outcome,
      running:$running,target:$target,
      reason:(if $reason == "" then null else $reason end),
      remediation:(if $remediation == "" then null else $remediation end),
      log:(if $log == "" then null else $log end)}' >"$temporary"
  mv -f "$temporary" "$file"
  log_event "converge $1: $4"
}

# The closing lines of a run that did not switch: what happened and where the
# detail went, in the same shape apply_epilogue gives a switch.
converge_epilogue() { # outcome host detail
  log_event "apply finished for $2 ($1)"
  case "$1" in
    current) printf '\n%s %s\n' "$(paint '1;32' 'Nothing to converge for')" "$(paint 36 "$2")" >&2 ;;
    held) printf '\n%s %s\n' "$(paint '1;33' 'Converge held for')" "$(paint 36 "$2")" >&2 ;;
  esac
  summary_line '' "$3"
  [[ -z "$RUN_LOG" ]] || summary_line log "$(paint 36 "$RUN_LOG")"
}

# A timer cannot type a password. Where activation elevates, the floor exists
# only on machines whose sudo answers without one; elsewhere the run holds
# before it builds anything, so a laptop never downloads a closure it cannot
# switch to. Asked, not assumed: the same registry entry describes a machine
# whose sudoers changed by hand.
converge_can_elevate() { # activation
  case "$1" in
    nix-darwin | nixos | nixos-wsl) ;;
    *) return 0 ;;
  esac
  [[ "$(id -u)" -ne 0 ]] || return 0
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_SUDO_NONINTERACTIVE:-}" ]]; then
    [[ "$_ATYRODE_TEST_SUDO_NONINTERACTIVE" == 1 ]]
    return
  fi
  sudo -n true 2>/dev/null
}

# The closure an unattended run may activate is one CI already built: a dry
# build that would compile anything locally says main has not been published
# yet (or this machine does not trust the cache), and either way the answer is
# to wait, not to spend the night compiling on a laptop. Nix prints the
# derivations it would realise before anything else; an empty answer is the
# proof that everything substitutes.
converge_published() { # installable
  local nix_program=nix output
  [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX:-}" ]] || nix_program="$ATYRODE_NIX"
  show_command "$nix_program" build --dry-run --no-link "$1"
  output="$("$nix_program" build --dry-run --no-link "$1" 2>&1)" || return 2
  [[ "$output" != *"will be built"* ]]
}

# The published head of main, asked for directly; a machine offline answers
# nothing rather than something stale, and callers say so.
converge_published_revision() {
  local git_command=git rev
  [[ "$test_hooks" != 1 || -z "${ATYRODE_GIT:-}" ]] || git_command="$ATYRODE_GIT"
  rev="$("$git_command" ls-remote "$flake_remote_url" refs/heads/main 2>/dev/null | head -n 1 | cut -f 1)" || true
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$rev"
}

# The doctor's view: which revision runs, which one main has, and what the last
# unattended run made of the difference. Drift is a finding with a remedy, a
# hold is the remedy the run itself named, and a development build carries no
# revision to compare, so it can only report the receipt.
probe_convergence() {
  local receipt outcome at target reason remediation published=""
  receipt="$(converge_receipt_file)"
  if [[ ! "$embedded_revision" =~ ^[0-9a-f]{40}$ ]]; then
    provisioning_check_add convergence not-applicable development-build \
      "this CLI is a development build and names no published revision to compare" ""
    return 0
  fi
  published="$(converge_published_revision)" || true
  if [[ -f "$receipt" ]]; then
    outcome="$(jq -r '.outcome // empty' "$receipt" 2>/dev/null || true)"
    at="$(jq -r '.at // empty' "$receipt" 2>/dev/null || true)"
    target="$(jq -r '.target // empty' "$receipt" 2>/dev/null || true)"
    reason="$(jq -r '.reason // empty' "$receipt" 2>/dev/null || true)"
    remediation="$(jq -r '.remediation // empty' "$receipt" 2>/dev/null || true)"
  fi
  if [[ -z "$published" ]]; then
    if [[ -n "${outcome:-}" && "$outcome" != current && "$outcome" != converged ]]; then
      provisioning_check_add convergence degraded "$outcome" \
        "main is unreachable; the last unattended run at $at $outcome at ${target:0:12}: $reason" \
        "$remediation"
    else
      provisioning_check_add convergence degraded main-unreachable \
        "main is unreachable, so drift is unknown; this machine runs ${embedded_revision:0:12}" ""
    fi
    return 0
  fi
  if [[ "$published" == "$embedded_revision" ]]; then
    provisioning_check_add convergence ok "" \
      "this machine runs ${embedded_revision:0:12}, which is main" ""
    return 0
  fi
  if [[ "${outcome:-}" == held && "$target" == "$published" ]]; then
    provisioning_check_add convergence degraded held \
      "main is ${published:0:12} and this machine runs ${embedded_revision:0:12}; the unattended run at $at held: $reason" \
      "$remediation"
    return 0
  fi
  if [[ "${outcome:-}" == failed && "$target" == "$published" ]]; then
    provisioning_check_add convergence degraded failed \
      "main is ${published:0:12} and this machine runs ${embedded_revision:0:12}; the unattended run at $at failed: $reason" \
      "${remediation:-atyrode apply}"
    return 0
  fi
  provisioning_check_add convergence degraded behind \
    "main is ${published:0:12} and this machine runs ${embedded_revision:0:12}; the timer has not converged it yet" \
    "atyrode apply"
}

# The login shell's inbox, read from the receipt alone -- a prompt never waits
# on the network, so this is the last run's verdict, dated. Two kinds of
# message: news, shown once (an update landed overnight), and unfinished
# business, shown on every new shell until the receipt changes (an update is
# waiting on the operator, or the run failed). Nothing to say when the machine
# was simply found current.
converge_shell_notice() {
  local receipt seen outcome at target reason remediation
  receipt="$(converge_receipt_file)"
  [[ -f "$receipt" ]] || return 0
  seen="${receipt%.json}.seen"
  outcome="$(jq -r '.outcome // empty' "$receipt" 2>/dev/null || true)"
  at="$(jq -r '.at // empty' "$receipt" 2>/dev/null || true)"
  target="$(jq -r '.target // empty' "$receipt" 2>/dev/null || true)"
  reason="$(jq -r '.reason // empty' "$receipt" 2>/dev/null || true)"
  remediation="$(jq -r '.remediation // empty' "$receipt" 2>/dev/null || true)"
  case "$outcome" in
    converged)
      [[ "$(cat "$seen" 2>/dev/null || true)" != "$at" ]] || return 0
      printf '%s\n' "$(muted "atyrode: updated to ${target:0:12} at $at while you were away")"
      printf '%s\n' "$at" >"$seen" 2>/dev/null || true
      ;;
    held)
      printf '%s\n' "$(muted "atyrode: an update to ${target:0:12} is waiting since $at: $reason")"
      [[ -z "$remediation" ]] || printf '%s\n' "$(muted "  fix with: $remediation")"
      ;;
    failed)
      printf '%s\n' "$(muted "atyrode: the update to ${target:0:12} failed at $at: $reason")"
      [[ -z "$remediation" ]] || printf '%s\n' "$(muted "  fix with: $remediation")"
      ;;
  esac
}
