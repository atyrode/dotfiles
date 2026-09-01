#!/usr/bin/env bash
set -euo pipefail

# One-time seed of curated Codex defaults into writable
# `~/.codex/config.toml`. Once applied, the marker prevents reapplication and
# the file is fully user-owned. A pre-existing config is timestamp-backed-up
# before the first install.

# The voice this seed shares with the CLI and the other ceremonies. Home
# Manager runs it unattended during activation, where the few lines it prints
# are the operator's only account of a config file appearing in their home
# directory; they should sound like the rest of the machine rather than like a
# stray script that got loose.
# shellcheck source=/dev/null
. "${ATYRODE_NARRATE:?the narration library was not provided}"
NARRATE_NAME=codex-seed

seed_file="${CODEX_SEED_FILE:?CODEX_SEED_FILE must point at the seed config.toml}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
target="$codex_home/config.toml"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/codex-seed"
marker="$state_root/seeded"
dry_run="${AGENT_TOOLS_DRY_RUN:-0}"

fail() {
  refuse "$NARRATE_NAME" "$1"
  exit 1
}

ensure_state_root() {
  mkdir -p "$state_root"
  chmod 700 "$state_root"
}

acquire_lock() {
  ensure_state_root
  exec 9>"$state_root/.lock"
  flock -w 15 9 || fail "another codex-seed run holds the lock"
}

cmd_apply() {
  # Read-only checks first so a dry run (and an already-seeded machine) touch
  # nothing on disk — not even the state dir or lock.
  if [[ -e "$marker" ]]; then
    say "$NARRATE_NAME: already seeded; leaving $target untouched"
    return 0
  fi
  [[ -f "$seed_file" ]] || fail "seed file missing: $seed_file"

  if [[ "$dry_run" == 1 ]]; then
    if [[ -e "$target" || -L "$target" ]]; then
      say "$NARRATE_NAME: DRY RUN — would back up $target and install the curated defaults"
    else
      say "$NARRATE_NAME: DRY RUN — would install the curated defaults at $target"
    fi
    return 0
  fi

  acquire_lock
  # Re-check under the lock in case a concurrent run seeded first.
  if [[ -e "$marker" ]]; then
    say "$NARRATE_NAME: already seeded; leaving $target untouched"
    return 0
  fi

  mkdir -p "$codex_home"
  chmod 700 "$codex_home"
  if [[ -e "$target" || -L "$target" ]]; then
    local backup
    backup="$target.pre-seed.$(date +%Y%m%d-%H%M%S)"
    run_visible mv -f -- "$target" "$backup"
    say "$NARRATE_NAME: backed up existing config to $backup"
  fi
  run_visible install -m 600 -- "$seed_file" "$target"
  printf 'seeded %s from %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$seed_file" >"$marker"
  say "$NARRATE_NAME: installed curated Codex defaults at $target"
  say "$NARRATE_NAME: recorded the one-time marker at $marker"
}

cmd_status() {
  local seeded=false detail=""
  if [[ -e "$marker" ]]; then
    seeded=true
    detail="$(cat "$marker" 2>/dev/null || true)"
  fi
  if [[ "${1:-}" == "--json" ]]; then
    printf '{"seeded":%s,"target":"%s","marker":"%s"}\n' "$seeded" "$target" "$marker"
  elif [[ "$seeded" == true ]]; then
    printf 'codex-seed: seeded (%s)\n' "$detail"
  else
    printf 'codex-seed: not yet seeded\n'
  fi
}

case "${1:-apply}" in
  apply) cmd_apply ;;
  status)
    shift
    cmd_status "${1:-}"
    ;;
  *) fail "unknown command: ${1} (expected apply|status)" ;;
esac
