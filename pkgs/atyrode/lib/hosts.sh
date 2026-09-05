# shellcheck shell=bash
#
# The host registry: resolving which machine this is, and what the
# reviewed inventory says it should be.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

runtime_identity_json() {
  local data="$1" user home uid owner_uid passwd_home=""
  user="$(actual_user)"
  home="$(actual_home)"
  if [[ "$test_hooks" == 1 ]]; then
    uid="${_ATYRODE_TEST_UID:-1000}"
    owner_uid="${_ATYRODE_TEST_HOME_OWNER_UID:-$uid}"
    passwd_home="${_ATYRODE_TEST_PASSWD_HOME:-$home}"
  else
    uid="$(id -u)"
    [[ -n "$home" && "$home" == /* && -d "$home" ]] ||
      die "$EX_DATAERR" "runtime profile requires an existing absolute HOME"
    owner_uid="$(stat -c '%u' -- "$home")" ||
      die "$EX_DATAERR" "cannot determine HOME ownership: $home"
    if command -v getent >/dev/null 2>&1; then
      passwd_home="$(getent passwd "$user" | cut -d: -f6 || true)"
    fi
  fi
  [[ "$uid" != 0 && "$user" != root ]] ||
    die "$EX_DATAERR" "runtime profiles cannot activate as root"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] ||
    die "$EX_DATAERR" "runtime profile found an invalid username"
  [[ -n "$home" && "$home" == /* && "$home" != *$'\n'* ]] ||
    die "$EX_DATAERR" "runtime profile requires an absolute HOME"
  [[ "$owner_uid" == "$uid" ]] ||
    die "$EX_DATAERR" "runtime profile HOME is not owned by the invoking user: $home"
  [[ -z "$passwd_home" || "$passwd_home" == "$home" ]] ||
    die "$EX_DATAERR" "runtime profile HOME does not match the account database: $home"
  jq -c --arg user "$user" --arg home "$home" \
    '. + {username:$user,homeDirectory:$home}' <<<"$data"
}

resolve_host() {
  local requested="${1:-}" recorded="" inherited="${ATYRODE_HOST:-}"
  # Home Manager generates this environment value; an old login or user
  # manager can retain it after a rename. Only a registered value selects a
  # host. An explicit argument still fails rather than silently changing target.
  if [[ -z "$requested" && -n "$inherited" ]] &&
    jq -e --arg inherited "$inherited" 'has($inherited)' "$registry" >/dev/null; then
    requested="$inherited"
  fi
  if [[ -z "$requested" && -r "${XDG_CONFIG_HOME:-$HOME/.config}/atyrode/host.json" ]]; then
    recorded="$(jq -r '.id // empty' "${XDG_CONFIG_HOME:-$HOME/.config}/atyrode/host.json")"
    if [[ -n "$recorded" ]] && jq -e --arg recorded "$recorded" 'has($recorded)' "$registry" >/dev/null; then
      requested="$recorded"
    fi
  fi
  if [[ -n "$requested" ]]; then
    jq -er --arg requested "$requested" '
      if has($requested) then $requested else empty end
    ' "$registry" || die "$EX_DATAERR" "unknown host: $requested"
    return
  fi

  local system user hostname matches
  system="$(actual_system)"
  user="$(actual_user)"
  hostname="$(actual_hostname)"
  matches="$(jq -r --arg system "$system" --arg user "$user" --arg hostname "$hostname" --arg inherited "$inherited" '
    [to_entries[]
      | select((.value.identityMode // "fixed") == "fixed")
      | select(.value.system == $system and .value.username == $user)]
    | ((map(select(.value.hostname == $hostname))) // []) as $exact
    | if ($exact | length) == 1 then $exact[0].key
      elif length == 1 and $inherited == "" then .[0].key
      else empty end
  ' "$registry")"
  [[ -n "$matches" ]] || die "$EX_DATAERR" "host identity is ambiguous; pass a registered host explicitly"
  printf '%s\n' "$matches"
}

host_json() {
  local data
  data="$(jq -c --arg host "$1" '.[$host]' "$registry")"
  if [[ "$(jq -r '.identityMode // "fixed"' <<<"$data")" == runtime ]]; then
    runtime_identity_json "$data"
  else
    printf '%s\n' "$data"
  fi
}

capabilities() {
  local action="${1:-list}" requested="" json=0
  shift || true
  if [[ "$action" == show && $# -gt 0 && "$1" != --json ]]; then
    requested="$1"
    shift
  fi
  [[ "${1:-}" != --json ]] || json=1
  case "$action" in
    list)
      # Mark the capabilities selected by the resolved host when one
      # resolves; on unregistered machines the list stays unmarked.
      local active="[]" host=""
      # die inside the substitution exits the subshell itself, so the
      # unresolved-host guard has to sit outside it.
      host="$(resolve_host 2>/dev/null)" || host=""
      [[ -z "$host" ]] || active="$(host_json "$host" | jq -c '.capabilities')"
      if [[ "$json" == 1 ]]; then
        jq -c --argjson active "$active" \
          'sort_by(.name) | map(. + {active: (.name as $n | $active | index($n) != null)})' \
          "$capability_inventory"
      else
        jq -r --argjson active "$active" \
          'sort_by(.name)[] | "\(.name)\(if (.name as $n | $active | index($n)) then " [active]" else "" end): \(.description)"' \
          "$capability_inventory"
      fi
      ;;
    show)
      local host data selected
      host="$(resolve_host "$requested")"
      data="$(host_json "$host")"
      selected="$(jq -c '.capabilities' <<<"$data")"
      if [[ "$json" == 1 ]]; then
        jq -c --argjson data "$data" --argjson selected "$selected" \
          '{host: $data.id, description: $data.description,
            capabilities: [sort_by(.name)[] | select(.name as $n | $selected | index($n))]}' \
          "$capability_inventory"
      else
        jq -r '"\(.id): \(.description)"' <<<"$data"
        jq -r --argjson selected "$selected" \
          'sort_by(.name)[] | select(.name as $n | $selected | index($n)) | "  \(.name): \(.description)"' \
          "$capability_inventory"
      fi
      ;;
    *) die "$EX_USAGE" "capabilities expects list or show" ;;
  esac
}

inventory() {
  local host="" ref="" repo="" json=0 system target manifest resolved_ref
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        shift
        [[ -n "${1:-}" ]] || die "$EX_USAGE" "--host expects a host name"
        host="$1"
        ;;
      --ref)
        shift
        [[ -n "${1:-}" ]] || die "$EX_USAGE" "--ref expects a Git revision"
        ref="$1"
        ;;
      --repo)
        shift
        [[ -n "${1:-}" ]] || die "$EX_USAGE" "--repo expects a flake path"
        repo="$1"
        ;;
      --json) json=1 ;;
      *) die "$EX_USAGE" "unknown inventory option: $1" ;;
    esac
    shift
  done
  [[ "$json" == 1 ]] || die "$EX_USAGE" "inventory currently requires --json"
  [[ -z "$ref" || -z "$repo" ]] || die "$EX_USAGE" "--ref and --repo are mutually exclusive"

  system="$(actual_system)"
  if [[ -n "$repo" ]]; then
    target="$repo#inventory.$system"
  elif [[ -n "$ref" ]]; then
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      resolved_ref="$ref"
    else
      resolved_ref="$(git ls-remote "$flake_remote_url" "refs/heads/$ref" "refs/tags/$ref" |
        head -n 1 | cut -f 1)" || true
      [[ -n "$resolved_ref" ]] ||
        die "$EX_UNAVAILABLE" "cannot resolve $ref on $flake_remote_url; check the ref name and network"
    fi
    target="$flake_ref/$resolved_ref#inventory.$system"
  else
    [[ "$embedded_revision" =~ ^[0-9a-f]{40}$ ]] ||
      die "$EX_UNAVAILABLE" "this development build has no immutable inventory revision; pass --ref or --repo"
    target="$flake_ref/$embedded_revision#inventory.$system"
  fi
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_INVENTORY:-}" ]]; then
    [[ -f "$_ATYRODE_TEST_INVENTORY" && ! -L "$_ATYRODE_TEST_INVENTORY" ]] ||
      die "$EX_DATAERR" "inventory fixture must be a regular file"
    manifest="$(jq -ec 'select(type == "object")' "$_ATYRODE_TEST_INVENTORY")" ||
      die "$EX_DATAERR" "inventory fixture is not a JSON object"
  else
    manifest="$(nix eval "$target" --json --no-write-lock-file)" ||
      die "$EX_UNAVAILABLE" "could not evaluate inventory from $target"
  fi
  if [[ -z "$host" ]]; then
    jq -cS . <<<"$manifest"
  else
    jq -ceS --arg requested "$host" '
      .hosts[$requested] as $match
      | if $match == null then error("unknown host: " + $requested)
        else {
          schemaVersion,
          identity,
          authority,
          host: $match
        }
        end
    ' <<<"$manifest" || die "$EX_DATAERR" "unknown host in evaluated inventory: $host"
  fi
}

portable_system_owner() {
  local data="$1"

  if is_nixos_owned "$data"; then
    printf 'nixos\n'
  else
    printf 'system\n'
  fi
}
