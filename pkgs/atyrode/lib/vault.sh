# shellcheck shell=bash
#
# Bitwarden session handling. Every secret path in the CLI comes through
# here.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

bw_program() {
  local command=bw
  [[ "$test_hooks" != 1 || -z "${ATYRODE_BW:-}" ]] || command="$ATYRODE_BW"
  printf '%s' "$command"
}

bw_cli() { "$(bw_program)" "$@"; }

# Announcements name the program that will actually run rather than the bw_cli
# wrapper, so what an operator reads is what they can paste back -- and under
# test hooks that is $ATYRODE_BW. bw_show announces without running, for the
# calls whose own redirections or pipelines leave run_visible nowhere to stand.
bw_show() { show_command "$(bw_program)" "$@"; }
bw_visible() { run_visible "$(bw_program)" "$@"; }

# The operator's Bitwarden account lives on the EU cloud. The bw CLI defaults
# to vault.bitwarden.com and then fails a first login on a fresh machine with
# a misleading "invalid master password", so pin the server before any login.
# Server changes are only accepted (and only needed) while unauthenticated.
readonly bitwarden_server="https://vault.bitwarden.eu"
vault_ensure_server() {
  local current
  current="$(bw_cli config server 2>/dev/null || true)"
  [[ "$current" == "$bitwarden_server" ]] && return 0
  bw_visible config server "$bitwarden_server" >/dev/null ||
    die "$EX_UNAVAILABLE" "could not point the Bitwarden CLI at $bitwarden_server"
}

vault_session=""
vault_unlocked_here=0

vault_status_value() {
  bw_cli status | jq -er '.status' ||
    die "$EX_UNAVAILABLE" "cannot read Bitwarden status"
}

vault_open_session() {
  local allow_login="$1" status
  vault_session=""
  vault_unlocked_here=0
  status="$(vault_status_value)"
  if [[ "$status" == unauthenticated && "$allow_login" == 1 ]]; then
    interactive || die "$EX_UNAVAILABLE" "Bitwarden login requires an interactive terminal"
    vault_ensure_server
    bw_visible login >/dev/null || die "$EX_UNAVAILABLE" "Bitwarden login failed"
    status="$(vault_status_value)"
  fi
  case "$status" in
    unlocked) ;;
    locked)
      # An unlock is the one command that stops and demands the master
      # password, and a prompt whose provenance the operator cannot establish
      # is indistinguishable from one a compromised script raised, so the argv
      # goes out ahead of it. Only the argv: the session token this prints is
      # captured from stdout and never reaches the terminal.
      if interactive; then
        vault_session="$(bw_visible unlock --raw)" ||
          die "$EX_UNAVAILABLE" "Bitwarden unlock failed"
      elif [[ -r /dev/tty && -w /dev/tty ]]; then
        vault_session="$(bw_visible unlock --raw </dev/tty)" ||
          die "$EX_UNAVAILABLE" "Bitwarden unlock failed"
      else
        die "$EX_UNAVAILABLE" "Bitwarden unlock requires an interactive terminal"
      fi
      export BW_SESSION="$vault_session"
      vault_unlocked_here=1
      ;;
    unauthenticated)
      die "$EX_UNAVAILABLE" "Bitwarden is not logged in; run 'atyrode vault login'"
      ;;
    *) die "$EX_SOFTWARE" "unsupported Bitwarden status: $status" ;;
  esac
}

vault_close_session() {
  if [[ "${vault_unlocked_here:-0}" == 1 ]]; then
    bw_show lock
    bw_cli lock >/dev/null 2>&1 || true
  fi
  unset BW_SESSION
  vault_session=""
  vault_unlocked_here=0
}

vault_secure_temp_dir() {
  local prefix="$1" root
  if [[ -d /dev/shm && -w /dev/shm ]]; then
    root=/dev/shm
  else
    root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  fi
  umask 077
  mktemp -d "$root/$prefix.XXXXXX"
}

vault_find_exact_item() {
  local name="$1" destination="$2"
  bw_cli list items --search "$name" |
    jq -e --arg name "$name" '[.[] | select(.name == $name)]' >"$destination" ||
    die "$EX_UNAVAILABLE" "could not search the Bitwarden vault"
  local count
  count="$(jq -er 'length' "$destination")"
  [[ "$count" -le 1 ]] ||
    die "$EX_DATAERR" "Bitwarden contains duplicate items named '$name'"
}

# vault_item_notes prints the notes body of the exact-name Bitwarden Secure
# Note NAME (opening a vault session as needed; missing, duplicate, and
# non-note items are refused). SCRATCH must be a caller-owned secure temp dir
# whose cleanup trap also calls vault_close_session — the lookup result it
# holds can contain secret material. ALLOW_LOGIN (default 0) lets an
# unauthenticated CLI log in interactively first — onboarding commands only,
# mirroring infra setup.
vault_item_notes() {
  local name="$1" scratch="$2" allow_login="${3:-0}" matches id
  matches="$scratch/matches.json"
  vault_open_session "$allow_login"
  bw_visible sync >/dev/null || die "$EX_UNAVAILABLE" "Bitwarden sync failed"
  vault_find_exact_item "$name" "$matches"
  [[ "$(jq -er 'length' "$matches")" == 1 ]] ||
    die "$EX_NOINPUT" "Bitwarden Secure Note '$name' does not exist"
  [[ "$(jq -er '.[0].type' "$matches")" == 2 ]] ||
    die "$EX_DATAERR" "Bitwarden item '$name' exists but is not a Secure Note"
  id="$(jq -er '.[0].id' "$matches")"
  bw_cli get item "$id" |
    jq -er '.notes | select(type == "string")' ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$name' has no text value"
}

# vault_store_note creates or updates the exact-name Secure Note NAME from
# SECRET_FILE. SCRATCH is a caller-owned secure temp dir under the caller's
# cleanup trap; the vault session must already be open (vault_open_session).
vault_store_note() {
  local name="$1" secret_file="$2" scratch="$3" matches id
  matches="$scratch/store-matches.json"
  [[ -s "$secret_file" ]] || die "$EX_DATAERR" "refusing to store an empty secret"
  bw_visible sync >/dev/null || die "$EX_UNAVAILABLE" "Bitwarden sync failed"
  vault_find_exact_item "$name" "$matches"
  # Either branch ends in a pipeline, which run_visible cannot wrap, so the
  # write announces itself: the argv shown is the mutation the pipeline
  # performs. The note body reaches bw on stdin and so never appears in the
  # words printed.
  if [[ "$(jq -er 'length' "$matches")" == 1 ]]; then
    [[ "$(jq -er '.[0].type' "$matches")" == 2 ]] ||
      die "$EX_DATAERR" "Bitwarden item '$name' exists but is not a Secure Note"
    id="$(jq -er '.[0].id' "$matches")"
    bw_show edit item "$id"
    bw_cli get item "$id" |
      jq -e --arg name "$name" --rawfile value "$secret_file" \
        '.name = $name | .type = 2 | .secureNote = {"type": 0} | .notes = $value' |
      bw_cli encode |
      bw_cli edit item "$id" >/dev/null ||
      die "$EX_UNAVAILABLE" "could not update Bitwarden Secure Note '$name'"
    printf 'atyrode: updated Bitwarden Secure Note %s\n' "$name" >&2
  else
    bw_show create item
    bw_cli get template item |
      jq -e --arg name "$name" --rawfile value "$secret_file" \
        '.name = $name | .type = 2 | .secureNote = {"type": 0} | .notes = $value' |
      bw_cli encode |
      bw_cli create item >/dev/null ||
      die "$EX_UNAVAILABLE" "could not create Bitwarden Secure Note '$name'"
    printf 'atyrode: created Bitwarden Secure Note %s\n' "$name" >&2
  fi
}

cmd_vault() {
  local action="${1:-}"
  case "$action" in
    status | login | lock | get | put) shift ;;
    *) die "$EX_USAGE" "vault expects status, login, lock, get, or put" ;;
  esac

  if [[ "$action" == status ]]; then
    local json=0
    if [[ "${1:-}" == --json ]]; then
      json=1
      shift
    fi
    [[ $# == 0 ]] || die "$EX_USAGE" "vault status accepts only --json"
    if [[ "$json" == 1 ]]; then
      bw_cli status
    else
      printf 'status: %s\n' "$(vault_status_value)"
    fi
    return
  fi

  guard_production_mutation "vault $action"
  case "$action" in
    login)
      [[ $# == 0 ]] || die "$EX_USAGE" "vault login takes no arguments"
      local status
      status="$(vault_status_value)"
      if [[ "$status" == unauthenticated ]]; then
        interactive || die "$EX_UNAVAILABLE" "Bitwarden login requires an interactive terminal"
        vault_ensure_server
        bw_visible login || die "$EX_UNAVAILABLE" "Bitwarden login failed"
      else
        printf 'atyrode: Bitwarden is already %s\n' "$status"
      fi
      ;;
    lock)
      [[ $# == 0 ]] || die "$EX_USAGE" "vault lock takes no arguments"
      bw_visible lock >/dev/null || die "$EX_UNAVAILABLE" "Bitwarden lock failed"
      printf 'atyrode: Bitwarden vault locked\n'
      ;;
    get | put)
      [[ $# == 1 && -n "$1" ]] ||
        die "$EX_USAGE" "vault $action expects exactly one item name"
      local name="$1" tmp secret_file=""
      tmp="$(vault_secure_temp_dir atyrode-vault)"
      vault_command_cleanup() {
        rm -rf -- "${tmp:-}"
        vault_close_session
      }
      trap vault_command_cleanup EXIT HUP INT TERM
      if [[ "$action" == get ]]; then
        vault_item_notes "$name" "$tmp"
      else
        vault_open_session 0
        secret_file="$tmp/secret"
        if [[ -t 0 ]]; then
          local secret
          read -r -s -p "Secret value: " secret ||
            die "$EX_DATAERR" "could not read the secret value"
          printf '\n' >&2
          printf '%s' "$secret" >"$secret_file"
          secret=""
        else
          cat >"$secret_file"
        fi
        vault_store_note "$name" "$secret_file" "$tmp"
      fi
      vault_command_cleanup
      trap - EXIT HUP INT TERM
      ;;
  esac
}
