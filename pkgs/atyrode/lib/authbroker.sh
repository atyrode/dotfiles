# shellcheck shell=bash
#
# The shared OMP authentication broker.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- shared OMP authentication broker -----------------------------------------
# OAuth refresh tokens rotate and remain broker-private. Bitwarden therefore
# custodies only the canonical broker's connection secret; every client reaches
# that one writer through an SSH tunnel. API keys are uploaded explicitly to the
# same broker and are never duplicated into per-machine credential stores.
auth_broker_vault_item='OMP auth broker'

auth_broker_config_file() {
  printf '%s/atyrode/omp-auth-broker/env\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

auth_broker_token_file() {
  printf '%s/atyrode/omp-auth-broker/token\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

auth_broker_require_safe_token() {
  [[ -n "$1" ]] || die "$EX_DATAERR" "OMP auth broker token is empty"
  if [[ "$1" == *$'\n'* || "$1" == *$'\r'* || "$1" == *'"'* ]]; then
    die "$EX_DATAERR" "OMP auth broker token contains invalid header characters"
  fi
}

auth_broker_restart_service() {
  local systemctl launchctl label
  if systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)"; then
    if "$systemctl" --user cat atyrode-omp-auth-brokers.service >/dev/null 2>&1; then
      "$systemctl" --user restart atyrode-omp-auth-brokers.service ||
        die "$EX_UNAVAILABLE" "could not restart the OMP auth broker tunnel"
      return
    fi

  fi
  if launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)"; then
    label="gui/$(id -u)/org.nix-community.home.atyrode-omp-auth-brokers"
    if "$launchctl" print "$label" >/dev/null 2>&1; then
      "$launchctl" kickstart -k "$label" ||
        die "$EX_UNAVAILABLE" "could not restart the OMP auth broker tunnel"
      return
    fi
  fi
  printf 'atyrode: broker config written; run atyrode apply (or restart atyrode-omp-auth-brokers) to start the tunnel\n' >&2
}

auth_broker_read_connection() {
  local config_file token_file
  config_file="$(auth_broker_config_file)"
  token_file="$(auth_broker_token_file)"
  OMP_AUTH_BROKER_URL=""
  OMP_AUTH_BROKER_TOKEN=""
  OMP_AUTH_BROKER_SSH_HOST=""
  if [[ -r "$config_file" ]]; then
    # Written by auth_broker_write_client_config with shell-escaped values.
    # shellcheck source=/dev/null
    source "$config_file"
  fi
  OMP_AUTH_BROKER_URL="${OMP_AUTH_BROKER_URL:-http://127.0.0.1:46171}"
  if [[ -z "${OMP_AUTH_BROKER_TOKEN:-}" && -r "$token_file" ]]; then
    OMP_AUTH_BROKER_TOKEN="$(<"$token_file")"
  fi
  [[ -n "$OMP_AUTH_BROKER_TOKEN" ]] ||
    die "$EX_NOINPUT" "OMP auth broker token is unavailable; run on the broker host or 'atyrode auth broker setup'"
  auth_broker_require_safe_token "$OMP_AUTH_BROKER_TOKEN"
}

auth_broker_write_client_config() {
  local note_file="$1" config_file config_dir tmp url token ssh_host
  config_file="$(auth_broker_config_file)"
  config_dir="$(dirname "$config_file")"
  url="$(jq -er '.url | select(type == "string" and length > 0)' "$note_file")" ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$auth_broker_vault_item' has no broker URL"
  token="$(jq -er '.token | select(type == "string" and length > 0)' "$note_file")" ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$auth_broker_vault_item' has no bearer token"
  auth_broker_require_safe_token "$token"
  ssh_host="$(jq -er '.sshHost | select(type == "string" and test("^[^[:space:]]+@[^[:space:]]+$"))' "$note_file")" ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$auth_broker_vault_item' has no valid SSH user@host"
  [[ "$(jq -er '.version' "$note_file")" == 1 ]] ||
    die "$EX_DATAERR" "Bitwarden Secure Note '$auth_broker_vault_item' has an unsupported version"
  [[ "$url" == "http://127.0.0.1:46171" ]] ||
    die "$EX_DATAERR" "SSH-tunnel broker URL must be http://127.0.0.1:46171"

  mkdir -p "$config_dir"
  chmod 700 "$config_dir"
  tmp="$(mktemp "$config_dir/.env.XXXXXX")"
  {
    printf 'OMP_AUTH_BROKER_MODE=client\n'
    printf 'OMP_AUTH_BROKER_URL=%q\n' "$url"
    printf 'OMP_AUTH_BROKER_TOKEN=%q\n' "$token"
    printf 'OMP_AUTH_BROKER_SSH_HOST=%q\n' "$ssh_host"
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$config_file"
  printf 'atyrode: configured shared OMP broker through %s\n' "$ssh_host" >&2
}

auth_broker_publish() {
  local via="" token_file token scratch note
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --via)
        shift
        via="${1:-}"
        ;;
      *) die "$EX_USAGE" "auth broker publish expects --via USER@HOST" ;;
    esac
    shift || true
  done
  [[ "$via" =~ ^[^[:space:]]+@[^[:space:]]+$ ]] ||
    die "$EX_USAGE" "auth broker publish requires --via USER@HOST"
  token_file="$(auth_broker_token_file)"
  [[ -r "$token_file" ]] ||
    die "$EX_NOINPUT" "local OMP broker token is missing at $token_file; apply agent-tools and start the broker first"
  token="$(<"$token_file")"
  [[ -n "$token" ]] || die "$EX_DATAERR" "local OMP broker token is empty"

  scratch="$(vault_secure_temp_dir atyrode-omp-auth)"
  auth_broker_require_safe_token "$token"
  auth_broker_vault_cleanup() {
    rm -rf -- "${scratch:-}"
    vault_close_session
  }
  trap auth_broker_vault_cleanup EXIT HUP INT TERM
  note="$scratch/broker.json"
  jq -n --arg url "http://127.0.0.1:46171" --arg sshHost "$via" --arg token "$token" \
    '{version:1,url:$url,sshHost:$sshHost,token:$token}' >"$note"
  chmod 600 "$note"
  vault_open_session 0
  vault_store_note "$auth_broker_vault_item" "$note" "$scratch"
  auth_broker_vault_cleanup
  trap - EXIT HUP INT TERM
  printf 'atyrode: shared broker bootstrap published for %s\n' "$via" >&2
}

auth_broker_setup() {
  local scratch note
  [[ $# == 0 ]] || die "$EX_USAGE" "auth broker setup takes no arguments"
  scratch="$(vault_secure_temp_dir atyrode-omp-auth)"
  auth_broker_setup_cleanup() {
    rm -rf -- "${scratch:-}"
    vault_close_session
  }
  trap auth_broker_setup_cleanup EXIT HUP INT TERM
  note="$scratch/broker.json"
  vault_item_notes "$auth_broker_vault_item" "$scratch" >"$note"
  auth_broker_write_client_config "$note"
  auth_broker_setup_cleanup
  trap - EXIT HUP INT TERM
  auth_broker_restart_service
}

auth_broker_status() {
  local json=0 config_file mode=local ssh_host="" token=false
  if [[ "${1:-}" == --json ]]; then
    json=1
    shift
  fi
  [[ $# == 0 ]] || die "$EX_USAGE" "auth broker status accepts only --json"
  config_file="$(auth_broker_config_file)"
  if [[ -r "$config_file" ]]; then
    # shellcheck source=/dev/null
    source "$config_file"
    mode="${OMP_AUTH_BROKER_MODE:-unknown}"
    ssh_host="${OMP_AUTH_BROKER_SSH_HOST:-}"
    [[ -n "${OMP_AUTH_BROKER_TOKEN:-}" ]] && token=true
  elif [[ -s "$(auth_broker_token_file)" ]]; then
    token=true
  fi
  if [[ "$json" == 1 ]]; then
    jq -nc --arg mode "$mode" --arg sshHost "$ssh_host" --argjson token "$token" \
      '{mode:$mode,configured:$token,sshHost:(if ($sshHost|length)>0 then $sshHost else null end)}'
  else
    printf 'mode: %s\n' "$mode"
    printf 'configured: %s\n' "$([[ "$token" == true ]] && printf yes || printf no)"
    [[ -z "$ssh_host" ]] || printf 'ssh host: %s\n' "$ssh_host"
  fi
}

auth_broker_add_api_key() {
  local provider="${1:-}" secret scratch payload response curl_cfg fetch
  [[ $# == 1 && "$provider" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "$EX_USAGE" "auth broker add-api-key expects one provider id"
  scratch="$(vault_secure_temp_dir atyrode-omp-api-key)"
  auth_broker_api_cleanup() { rm -rf -- "${scratch:-}"; }
  trap auth_broker_api_cleanup EXIT HUP INT TERM
  secret="$scratch/key"
  if [[ -t 0 ]]; then
    local value
    read -r -s -p "$provider API key: " value ||
      die "$EX_DATAERR" "could not read the API key"
    printf '\n' >&2
    printf '%s' "$value" >"$secret"
    value=""
  else
    cat >"$secret"
  fi
  [[ -s "$secret" ]] || die "$EX_DATAERR" "refusing to upload an empty API key"
  chmod 600 "$secret"
  auth_broker_read_connection
  payload="$scratch/payload.json"
  jq -en --arg provider "$provider" --rawfile key "$secret" '
    ($key | rtrimstr("\n")) as $key
    | if ($key | length) == 0 or ($key | test("[\r\n]"))
      then error("API key must be one non-empty line")
      else {provider:$provider,credential:{type:"api_key",key:$key}}
      end
  ' >"$payload"
  curl_cfg="$scratch/curl.cfg"
  printf 'header = "Authorization: Bearer %s"\n' "$OMP_AUTH_BROKER_TOKEN" >"$curl_cfg"
  chmod 600 "$curl_cfg"
  response="$scratch/response.json"
  fetch="$(optional_host_command ATYRODE_FETCH curl)" ||
    die "$EX_UNAVAILABLE" "curl is required to add an OMP API key"
  "$fetch" -fsS --config "$curl_cfg" -X POST \
    -H 'content-type: application/json' --data-binary "@$payload" \
    -o "$response" "$OMP_AUTH_BROKER_URL/v1/credential" ||
    die "$EX_UNAVAILABLE" "could not upload the $provider API key to the OMP broker"
  jq -e '.entries | type == "array"' "$response" >/dev/null ||
    die "$EX_DATAERR" "OMP broker returned an invalid credential response"
  auth_broker_api_cleanup
  trap - EXIT HUP INT TERM
  printf 'atyrode: added %s API key to the shared OMP broker\n' "$provider" >&2
}

cmd_auth() {
  [[ "${1:-}" == broker ]] || die "$EX_USAGE" "auth expects broker"
  shift
  local action="${1:-}"
  shift || true
  case "$action" in
    publish)
      guard_production_mutation "auth broker publish"
      auth_broker_publish "$@"
      ;;
    setup)
      guard_production_mutation "auth broker setup"
      auth_broker_setup "$@"
      ;;
    status) auth_broker_status "$@" ;;
    add-api-key)
      guard_production_mutation "auth broker add-api-key"
      auth_broker_add_api_key "$@"
      ;;
    *) die "$EX_USAGE" "auth broker expects publish, setup, status, or add-api-key" ;;
  esac
}
