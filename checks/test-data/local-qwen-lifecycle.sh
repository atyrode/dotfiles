#!/usr/bin/env bash
# shellcheck disable=SC2154 # Runtime state paths are provided by the sourced helper.
set -euo pipefail

runtime_helper="$1"
test_root="$(mktemp -d)"
other_pid=""
cleanup() {
  if [[ -n "$other_pid" ]]; then
    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME"

# Load the packaged helper's functions without invoking its CLI dispatcher.
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "$runtime_helper")

# A sole managed session arms the grace deadline when it exits.
(
  acquire_session_lease
  trap release_session_lease EXIT
  test -f "$session_lease_file"
  test ! -e "$idle_deadline_file"
)
test -f "$idle_deadline_file"
test "$(cat "$idle_deadline_file")" -gt "$(date +%s)"

# Releasing one session while another process lease is live must not arm a stop.
rm -f "$idle_deadline_file"
sleep 30 &
other_pid=$!
mkdir -p "$session_lease_root"
printf '%s %s\n' "$other_pid" "$(process_start_ticks "$other_pid")" >"$session_lease_root/$other_pid"
(
  acquire_session_lease
  trap release_session_lease EXIT
  test "$(find "$session_lease_root" -type f | wc -l)" = 2
)
test ! -e "$idle_deadline_file"
kill "$other_pid"
wait "$other_pid" 2>/dev/null || true
other_pid=""
lifecycle_lock_acquire
prune_session_leases_unlocked
test "$(active_session_count_unlocked)" = 0
lifecycle_lock_release

# A lock left by a dead process is recoverable and cannot block future runs.
printf '999999 1\n' >"$lifecycle_lock_file"
lifecycle_lock_acquire
read -r lock_pid _ <"$lifecycle_lock_file"
test "$lock_pid" = "$$"
lifecycle_lock_release

# Stub only the Docker/metrics boundary and exercise the reaper state machine.
DATA_DIR="$test_root/data"
mkdir -p "$DATA_DIR" "$config_root" "$state_root"
touch "$DATA_DIR/docker-compose.yml" "$DATA_DIR/.env" "$compose_override"
printf 'DATA_DIR=%q\nAUTOSTART=0\n' "$DATA_DIR" >"$config_file"
compose() {
  case "$*" in
    'ps --status running --quiet single') printf 'container-id\n' ;;
    'stop single') : >"$test_root/stopped" ;;
    *) return 1 ;;
  esac
}
metric_snapshot() {
  printf '%s\n' "$test_metric"
}

# Active requests postpone shutdown.
test_metric='1 100'
write_state_value_unlocked "$activity_counter_file" 100
write_state_value_unlocked "$idle_deadline_file" 1
(cmd_reap)
test ! -e "$test_root/stopped"
test "$(cat "$idle_deadline_file")" -gt "$(date +%s)"

# Token activity observed between timer ticks also postpones shutdown.
test_metric='0 101'
write_state_value_unlocked "$idle_deadline_file" 1
(cmd_reap)
test ! -e "$test_root/stopped"
test "$(cat "$activity_counter_file")" = 101
test "$(cat "$idle_deadline_file")" -gt "$(date +%s)"

# An expired, inactive, unchanged runtime is stopped and its idle state clears.
test_metric='0 101'
write_state_value_unlocked "$idle_deadline_file" 1
(cmd_reap)
test -e "$test_root/stopped"
test ! -e "$idle_deadline_file"
test ! -e "$activity_counter_file"
