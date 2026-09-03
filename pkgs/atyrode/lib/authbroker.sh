# shellcheck shell=bash
#
# The shared OMP authentication broker.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- shared OMP authentication broker -----------------------------------------
# OAuth refresh tokens rotate and remain broker-private. One machine of the
# fleet serves the broker (fleet/auth-broker.json names it) and every other
# reaches it through the SSH tunnel Home Manager keeps up; which is which is
# decided in Nix (modules/shared/omp-auth-broker.nix) and read here from the
# same inventory, never from a file on the machine. The bearer token is a
# shared clan var placed by sops-nix and linked to the path OMP reads it from;
# no verb here writes, copies, or prints it. API keys are uploaded explicitly
# to the broker and are never duplicated into per-machine credential stores.
auth_broker_url='http://127.0.0.1:46171'

# The link Home Manager installs to the placed token: OMP's own path for the
# default profile's configuration root, the one place both the broker and its
# clients resolve the token from.
auth_broker_token_file() {
  printf '%s/.omp/auth-broker.token\n' "$HOME"
}

auth_broker_host() {
  jq -er '.host | select(type == "string" and length > 0)' "$auth_broker_inventory" ||
    die "$EX_SOFTWARE" "fleet/auth-broker.json names no host"
}

# serve, tunnel, or none: a portable profile is not a clan machine and holds no
# token, so it has no side of the broker to be on.
auth_broker_mode() { # host
  if [[ "$(jq -r '.identityMode // "fixed"' <<<"$(host_json "$1")")" == runtime ]]; then
    printf 'none\n'
  elif [[ "$1" == "$(auth_broker_host)" ]]; then
    printf 'serve\n'
  else
    printf 'tunnel\n'
  fi
}

# Whether the placed token is readable through the link. `-s` follows it, so a
# value not yet generated reads as absent exactly as it did before it existed.
auth_broker_token_placed() {
  [[ -s "$(auth_broker_token_file)" ]]
}

auth_broker_require_safe_token() {
  [[ -n "$1" ]] || die "$EX_DATAERR" "OMP auth broker token is empty"
  if [[ "$1" == *$'\n'* || "$1" == *$'\r'* || "$1" == *'"'* ]]; then
    die "$EX_DATAERR" "OMP auth broker token contains invalid header characters"
  fi
}

# The user unit's state on this platform, or unknown where neither service
# manager answers. Read only: nothing here starts or restarts it.
auth_broker_service_state() {
  local systemctl launchctl label
  if systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)"; then
    if "$systemctl" --user cat atyrode-omp-auth-brokers.service >/dev/null 2>&1; then
      "$systemctl" --user show -P ActiveState atyrode-omp-auth-brokers.service 2>/dev/null ||
        printf 'unknown\n'
      return
    fi
  fi
  if launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)"; then
    label="gui/$(id -u)/org.nix-community.home.atyrode-omp-auth-brokers"
    if "$launchctl" print "$label" >/dev/null 2>&1; then
      printf 'active\n'
      return
    fi
  fi
  printf 'unknown\n'
}

auth_broker_status() {
  local json=0 host mode broker_host token=false service
  if [[ "${1:-}" == --json ]]; then
    json=1
    shift
  fi
  [[ $# == 0 ]] || die "$EX_USAGE" "auth broker status accepts only --json"
  host="$(resolve_host)"
  mode="$(auth_broker_mode "$host")"
  broker_host="$(auth_broker_host)"
  ! auth_broker_token_placed || token=true
  service="$(auth_broker_service_state)"
  if [[ "$json" == 1 ]]; then
    jq -nc --arg mode "$mode" --arg host "$broker_host" --argjson token "$token" \
      --arg service "$service" --arg tokenPath "$(auth_broker_token_file)" \
      '{mode:$mode,host:$host,configured:$token,tokenPath:$tokenPath,service:$service}'
  else
    printf 'mode: %s\n' "$mode"
    printf 'broker host: %s\n' "$broker_host"
    printf 'configured: %s\n' "$([[ "$token" == true ]] && printf yes || printf no)"
    printf 'token: %s\n' "$(auth_broker_token_file)"
    printf 'service: %s\n' "$service"
  fi
}

auth_broker_add_api_key() {
  local provider="${1:-}" secret scratch payload response curl_cfg fetch token
  [[ $# == 1 && "$provider" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "$EX_USAGE" "auth broker add-api-key expects one provider id"
  auth_broker_token_placed ||
    die "$EX_NOINPUT" "OMP auth broker token is not placed at $(auth_broker_token_file); generate it on an operator device (clan vars generate $(resolve_host)), then atyrode apply"
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
  token="$(<"$(auth_broker_token_file)")"
  auth_broker_require_safe_token "$token"
  payload="$scratch/payload.json"
  jq -en --arg provider "$provider" --rawfile key "$secret" '
    ($key | rtrimstr("\n")) as $key
    | if ($key | length) == 0 or ($key | test("[\r\n]"))
      then error("API key must be one non-empty line")
      else {provider:$provider,credential:{type:"api_key",key:$key}}
      end
  ' >"$payload"
  curl_cfg="$scratch/curl.cfg"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$curl_cfg"
  token=""
  chmod 600 "$curl_cfg"
  response="$scratch/response.json"
  fetch="$(optional_host_command ATYRODE_FETCH curl)" ||
    die "$EX_UNAVAILABLE" "curl is required to add an OMP API key"
  # Safe to print verbatim: the bearer token stays in the 0600 curl config and
  # the key itself in the payload file, so this argv carries only two paths and
  # the fixed loopback URL, the same on the broker host and through a tunnel.
  run_visible "$fetch" -fsS --config "$curl_cfg" -X POST \
    -H 'content-type: application/json' --data-binary "@$payload" \
    -o "$response" "$auth_broker_url/v1/credential" ||
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
    status) auth_broker_status "$@" ;;
    add-api-key)
      guard_production_mutation "auth broker add-api-key"
      auth_broker_add_api_key "$@"
      ;;
    *) die "$EX_USAGE" "auth broker expects status or add-api-key" ;;
  esac
}
