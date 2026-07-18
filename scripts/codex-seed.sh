#!/usr/bin/env bash
set -euo pipefail

# One-time seed of curated Codex defaults into writable
# `~/.codex/config.toml`. Once applied, the marker prevents reapplication and
# the file is fully user-owned. A pre-existing config is timestamp-backed-up
# before the first install.

seed_file="${CODEX_SEED_FILE:?CODEX_SEED_FILE must point at the seed config.toml}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
target="$codex_home/config.toml"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/codex-seed"
marker="$state_root/seeded"
dry_run="${AGENT_TOOLS_DRY_RUN:-0}"

fail() {
  printf 'codex-seed: %s\n' "$1" >&2
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
    printf 'codex-seed: already seeded; leaving %s untouched\n' "$target" >&2
    return 0
  fi
  [[ -f "$seed_file" ]] || fail "seed file missing: $seed_file"

  if [[ "$dry_run" == 1 ]]; then
    if [[ -e "$target" || -L "$target" ]]; then
      printf 'codex-seed: DRY RUN — would back up %s and install the curated defaults\n' "$target" >&2
    else
      printf 'codex-seed: DRY RUN — would install the curated defaults at %s\n' "$target" >&2
    fi
    return 0
  fi

  acquire_lock
  # Re-check under the lock in case a concurrent run seeded first.
  if [[ -e "$marker" ]]; then
    printf 'codex-seed: already seeded; leaving %s untouched\n' "$target" >&2
    return 0
  fi

  mkdir -p "$codex_home"
  chmod 700 "$codex_home"
  if [[ -e "$target" || -L "$target" ]]; then
    local backup
    backup="$target.pre-seed.$(date +%Y%m%d-%H%M%S)"
    mv -f -- "$target" "$backup"
    printf 'codex-seed: backed up existing config to %s\n' "$backup" >&2
  fi
  install -m 600 -- "$seed_file" "$target"
  printf 'seeded %s from %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$seed_file" >"$marker"
  printf 'codex-seed: installed curated Codex defaults at %s\n' "$target" >&2
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
