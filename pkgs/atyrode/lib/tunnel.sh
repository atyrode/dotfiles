# shellcheck shell=bash
#
# Fleet SSH access: which reviewed keys may reach this machine.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- fleet SSH access (tunnel) ------------------------------------------------
# Which reviewed fleet keys may reach THIS machine over SSH. Two inputs, one
# output: the git-owned registry (home/ssh-fleet-keys, public keys only, changed
# only by a reviewed commit) and a machine-local grant file holding this host's
# own decisions. ~/.ssh/authorized_keys is rendered from both and owned here, so
# a hand-edited or half-pasted line cannot silently grant or lose access.
#
# Expiry is delegated to sshd. A timed grant renders OpenSSH's own
# expiry-time="YYYYMMDDHHMM" option, which sshd evaluates when the key is
# offered. Nothing has to still be running for a grant to lapse: no timer, no
# daemon, no reachable machine. Pruning a lapsed row from the state file is
# hygiene, never the mechanism.
#
# The vault gate on grant/revoke proves an operator is present. It is not a
# privilege boundary: see docs/atyrode.md ("Fleet SSH access").
readonly tunnel_managed_marker='# Managed by atyrode tunnel. Do not edit.'

tunnel_state_file() {
  printf '%s/atyrode/tunnel/grants.json\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

tunnel_authorized_keys_file() { printf '%s/.ssh/authorized_keys\n' "$HOME"; }
tunnel_backup_file() { printf '%s/.ssh/authorized_keys.pre-atyrode\n' "$HOME"; }

# The durations both surfaces offer. The cockpit's picker renders exactly this
# set, so a grant made in the TUI and one made headlessly cannot mean different
# things. `until-revoked` is the only unbounded option and has to be named.
tunnel_duration_seconds() {
  case "$1" in
    1h) printf '3600\n' ;;
    8h) printf '28800\n' ;;
    24h) printf '86400\n' ;;
    7d) printf '604800\n' ;;
    until-revoked) printf '0\n' ;;
    *) die "$EX_USAGE" "unknown grant duration: $1 (expected 1h, 8h, 24h, 7d, or until-revoked)" ;;
  esac
}

# The registry is reviewed data, so every shape error is reported against the
# file rather than tolerated: a typo must not silently drop a machine from the
# fleet or, worse, leave zero primary keys and no lockout protection.
tunnel_registry_json() {
  jq -n --rawfile registry "$managed_ssh_fleet_keys" '
    ($registry
      | split("\n")
      | map(select(test("^[ \t]*(#|$)") | not) | [splits("[ \t]+")] | map(select(length > 0)))
      | map(select(length > 0))) as $lines
    | ($lines | map(
        if length != 4 then
          error("home/ssh-fleet-keys expects `NAME ROLE KEYTYPE KEY`, got: \(join(" "))")
        elif (.[0] | test("^[a-z0-9][a-z0-9-]*$") | not) then
          error("home/ssh-fleet-keys name is not a lowercase identifier: \(.[0])")
        elif (.[1] | IN("primary", "revocable") | not) then
          error("home/ssh-fleet-keys role must be primary or revocable, got: \(.[1])")
        elif (.[2] | test("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com)$") | not) then
          error("home/ssh-fleet-keys key type is unsupported: \(.[2])")
        elif (.[3] | test("^AAAA[A-Za-z0-9+/]+={0,3}$") | not) then
          error("home/ssh-fleet-keys key material is not base64 for: \(.[0])")
        else
          { name: .[0], role: .[1], primary: (.[1] == "primary"), keytype: .[2], key: .[3] }
        end)) as $entries
    | if ($entries | length) == 0 then
        error("home/ssh-fleet-keys registers no keys")
      elif ($entries | map(.name) | unique | length) != ($entries | length) then
        error("home/ssh-fleet-keys registers a duplicate machine name")
      elif ($entries | map(.key) | unique | length) != ($entries | length) then
        error("home/ssh-fleet-keys registers the same key twice")
      elif ($entries | map(select(.primary)) | length) != 1 then
        error("home/ssh-fleet-keys must mark exactly one key primary, found \($entries | map(select(.primary)) | length)")
      else $entries end
  ' || die "$EX_DATAERR" "the fleet key registry is unusable"
}

tunnel_state_read() {
  local file
  file="$(tunnel_state_file)"
  if [[ ! -e "$file" ]]; then
    printf '{"schemaVersion":1,"grants":[]}\n'
    return
  fi
  [[ ! -L "$file" ]] ||
    die "$EX_DATAERR" "$file is a symlink; refusing to read grant state through it"
  jq -e '
    if .schemaVersion == 1 and (.grants | type == "array")
      and (.grants | all(has("name") and has("expiresAt")))
    then . else error("unsupported grant state contract") end
  ' "$file" ||
    die "$EX_DATAERR" "$file is not a supported atyrode tunnel grant state file"
}

# Every public key blob present in the current authorized_keys, malformed
# surroundings included: a blob is what sshd matches on, and a blob this machine
# cannot name is exactly what a render must refuse to discard.
tunnel_existing_key_blobs() {
  local file
  file="$(tunnel_authorized_keys_file)"
  [[ -f "$file" ]] || return 0
  grep -oE 'AAAA[A-Za-z0-9+/]{20,}={0,3}' "$file" || true
}

# Whether atyrode already owns the rendered file. Before it does, the keys in
# authorized_keys are the operator's own decisions and grant state is silent
# about them; afterwards grant state is authoritative and a key's absence from
# it is a revocation, not an omission.
tunnel_file_is_managed() {
  local file
  file="$(tunnel_authorized_keys_file)"
  [[ -f "$file" ]] && grep -qF "$tunnel_managed_marker" "$file"
}

# Fingerprints, never key material, are what the human-facing surfaces print.
# openssh reads each key from stdin, so no public key is spilled to disk.
tunnel_fingerprints_json() { # fleet
  local fleet="$1" name keytype key fingerprint fingerprints='{}'
  while IFS=$'\t' read -r name keytype key; do
    fingerprint="$(printf '%s %s %s\n' "$keytype" "$key" "$name" |
      ssh-keygen -lf - 2>/dev/null | gawk '{print $2}')" || fingerprint=""
    [[ -n "$fingerprint" ]] ||
      die "$EX_DATAERR" "home/ssh-fleet-keys holds a key openssh cannot parse: $name"
    fingerprints="$(jq -c --arg name "$name" --arg fingerprint "$fingerprint" \
      '.[$name] = $fingerprint' <<<"$fingerprints")"
  done < <(jq -r '.[] | [.name, .keytype, .key] | @tsv' <<<"$fleet")
  printf '%s\n' "$fingerprints"
}

# registry x grants x authorized_keys x now -> the one report every surface
# reads: `tunnel list`, the renderer, and the cockpit panel. Liveness is derived
# here, so a lapsed grant reads as expired everywhere before anything has pruned
# it, and a key sshd accepts today never reads as ungranted just because this
# machine has not adopted it into grant state yet.
tunnel_report_json() {
  local fleet state fingerprints now managed=false
  fleet="$(tunnel_registry_json)"
  state="$(tunnel_state_read)"
  fingerprints="$(tunnel_fingerprints_json "$fleet")"
  now="$(date -u +%s)"
  ! tunnel_file_is_managed || managed=true
  jq -nc --argjson fleet "$fleet" --argjson state "$state" \
    --argjson fingerprints "$fingerprints" --argjson now "$now" \
    --arg registryPath "$managed_ssh_fleet_keys" \
    --arg statePath "$(tunnel_state_file)" \
    --arg authorizedKeys "$(tunnel_authorized_keys_file)" \
    --arg present "$(tunnel_existing_key_blobs)" --argjson managed "$managed" '
    ($state.grants | map({ (.name): . }) | add // {}) as $grants
    | ($present | split("\n") | map(select(length > 0)) | unique) as $present
    | { schemaVersion: 1,
        now: $now,
        registryPath: $registryPath,
        statePath: $statePath,
        authorizedKeys: $authorizedKeys,
        machines: ($fleet | map(
          . as $entry
          | $grants[$entry.name] as $grant
          | (if $grant == null then null else $grant.expiresAt end) as $expires
          | (($present | index($entry.key)) != null) as $live
          | (if $entry.primary then "primary"
             elif $grant != null and $expires == null then "granted"
             elif $grant != null and $expires > $now then "timed"
             elif $grant != null then "expired"
             elif $live and ($managed | not) then "unmanaged"
             else "revoked" end) as $row
          | { name: $entry.name,
              role: $entry.role,
              primary: $entry.primary,
              keytype: $entry.keytype,
              fingerprint: $fingerprints[$entry.name],
              state: $row,
              granted: ($row | IN("primary", "granted", "timed", "unmanaged")),
              expiresAt: (if $row == "timed" then $expires else null end),
              remainingSeconds: (if $row == "timed" then $expires - $now else null end) })) }'
}

# The rendered expiry option. sshd reads an expiry-time without a Z suffix in
# the system time zone, so the deadline is formatted in local time from the
# stored epoch second: one conversion, in the direction sshd will read it.
tunnel_expiry_option() { # epoch
  date -d "@$1" +%Y%m%d%H%M
}

# Adoption writes the grant file once per key it takes over, so the path is
# named on the first write only: repeating it would bury the lines that say
# what actually changed.
tunnel_state_announced=0

# mode(grant|revoke) name expiresAt(JSON null or epoch) -- upsert or delete, and
# drop every lapsed row while the file is open.
tunnel_state_apply() {
  local mode="$1" name="$2" expires="${3:-null}" file dir temp now next
  file="$(tunnel_state_file)"
  dir="$(dirname "$file")"
  now="$(date -u +%s)"
  mkdir -p "$dir"
  chmod 700 "$dir"
  [[ ! -L "$file" ]] ||
    die "$EX_DATAERR" "$file is a symlink; refusing to write grant state through it"
  next="$(tunnel_state_read |
    jq --arg name "$name" --arg mode "$mode" --argjson expires "$expires" \
      --argjson now "$now" '
      .schemaVersion = 1
      | .grants = ((.grants
          | map(select(.name != $name))
          | map(select(.expiresAt == null or .expiresAt > $now)))
          + (if $mode == "revoke" then []
             else [{ name: $name, grantedAt: $now, expiresAt: $expires }] end)
          | sort_by(.name))')" ||
    die "$EX_SOFTWARE" "could not update the grant state"
  temp="$(mktemp "$dir/.grants.XXXXXX")"
  printf '%s\n' "$next" >"$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$file"
  # The atomic install is bookkeeping; which file now decides who may reach
  # this machine is not, so the path is named in prose rather than shown as an
  # mv of a temp name the operator could never retype.
  if [[ "$tunnel_state_announced" == 0 ]]; then
    tunnel_state_announced=1
    printf 'atyrode: updated the grant state in %s\n' "$file" >&2
  fi
}

# One-time adoption. Before this machine has any grant state, the keys already
# in authorized_keys are the operator's live decisions; discarding them would
# make the first grant a silent revocation of every other machine -- including,
# on a headless host, the key carrying the session doing the granting. Adopted
# grants are unbounded, because that is what an authorized_keys line with no
# expiry-time option already meant.
tunnel_adopt_existing_grants() { # fleet
  local fleet="$1" blobs adopted name
  [[ ! -e "$(tunnel_state_file)" ]] || return 0
  ! tunnel_file_is_managed || return 0
  blobs="$(tunnel_existing_key_blobs)"
  [[ -n "$blobs" ]] || return 0
  adopted="$(jq -nr --argjson fleet "$fleet" --arg blobs "$blobs" '
    ($blobs | split("\n") | map(select(length > 0)) | unique) as $present
    | $fleet
    | map(select(.primary | not))
    | map(select(.key as $key | $present | index($key)))
    | map(.name)
    | .[]')"
  while read -r name; do
    [[ -n "$name" ]] || continue
    tunnel_state_apply grant "$name" null
    printf 'atyrode: adopted the existing grant for %s (until revoked)\n' "$name" >&2
  done <<<"$adopted"
}

# A key this machine cannot name must never be dropped by a render. Either it
# belongs to the fleet and belongs in the reviewed registry, or it does not
# belong in authorized_keys at all -- both are the operator's call, not this
# command's.
tunnel_refuse_unknown_keys() { # fleet
  local fleet="$1" blobs unknown file blob
  file="$(tunnel_authorized_keys_file)"
  blobs="$(tunnel_existing_key_blobs)"
  [[ -n "$blobs" ]] || return 0
  unknown="$(jq -nr --argjson fleet "$fleet" --arg blobs "$blobs" '
    ($blobs | split("\n") | map(select(length > 0)) | unique) as $present
    | ($fleet | map(.key)) as $known
    | ($present - $known) | .[]')"
  [[ -n "$unknown" ]] || return 0
  while read -r blob; do
    [[ -n "$blob" ]] || continue
    printf 'atyrode: %s holds an unregistered key ending %s\n' "$file" "${blob: -12}" >&2
  done <<<"$unknown"
  die "$EX_DATAERR" "register those keys in home/ssh-fleet-keys through a reviewed commit (or remove them by hand) before atyrode renders $file"
}

# The rendered file is the only thing sshd reads, so it is written whole,
# atomically, and never merged with whatever was there before. The report is
# validated first: a truncated or empty one would otherwise render a keyless
# file, which on a headless machine is indistinguishable from a lockout.
tunnel_render() { # report fleet
  local report="$1" fleet="$2" ssh_dir file backup temp count
  jq -e '
    if .schemaVersion == 1
      and (.machines | type == "array")
      and ([.machines[] | select(.granted)] | length) > 0
      and any(.machines[]; .primary and .granted)
    then true else error("refusing to render an authorized_keys with no granted primary key") end
  ' <<<"${report:-null}" >/dev/null ||
    die "$EX_SOFTWARE" "the tunnel report is unusable; authorized_keys was left untouched"
  file="$(tunnel_authorized_keys_file)"
  ssh_dir="$(dirname "$file")"
  backup="$(tunnel_backup_file)"
  [[ ! -L "$file" ]] ||
    die "$EX_DATAERR" "$file is a symlink; refusing to render through it"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  tunnel_refuse_unknown_keys "$fleet"

  if [[ -f "$file" ]] && ! grep -qF "$tunnel_managed_marker" "$file" && [[ ! -e "$backup" ]]; then
    cp -- "$file" "$backup"
    chmod 600 "$backup"
    printf 'atyrode: kept the pre-management authorized_keys at %s\n' "$backup" >&2
  fi

  local -a lines=("$tunnel_managed_marker")
  lines+=("# Rendered from the reviewed fleet registry plus this machine's grant state:")
  lines+=("#   registry $managed_ssh_fleet_keys")
  lines+=("#   grants   $(tunnel_state_file)")
  lines+=('# Change it with: atyrode tunnel grant|revoke -- edits here are overwritten.')
  local name keytype expires option key
  while IFS=$'\t' read -r name keytype expires; do
    key="$(jq -r --arg name "$name" 'first(.[] | select(.name == $name) | .key)' <<<"$fleet")"
    if [[ "$expires" == null ]]; then
      lines+=("$keytype $key $name")
    else
      option="$(tunnel_expiry_option "$expires")"
      lines+=("expiry-time=\"$option\" $keytype $key $name")
    fi
  done < <(jq -r '
    .machines
    | map(select(.granted))
    | sort_by([(.primary | not), .name])
    | .[] | [.name, .keytype, (.expiresAt // "null" | tostring)] | @tsv' <<<"$report")

  temp="$(mktemp "$ssh_dir/.authorized_keys.XXXXXX")"
  printf '%s\n' "${lines[@]}" >"$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$file"
  count="$(jq -r '[.machines[] | select(.granted)] | length' <<<"$report")"
  printf 'atyrode: rendered %s with %s granted key(s)\n' "$file" "$count" >&2
}

# Reused from the storage ceremony and `provision git`: unlock when locked, then
# relock on every exit path only when this command opened the session.
tunnel_vault_cleanup() { vault_close_session; }

tunnel_vault_gate() {
  trap tunnel_vault_cleanup EXIT HUP INT TERM
  vault_open_session 0
}

tunnel_state_sentence() { # machine
  jq -r '
    if .state == "primary" then "always granted (primary, never revocable here)"
    elif .state == "granted" then "granted until revoked"
    elif .state == "timed" then
      "granted, expires in \((.remainingSeconds / 3600) | floor)h "
      + "\(((.remainingSeconds % 3600) / 60) | floor)m"
    elif .state == "expired" then "expired; sshd already refuses it"
    elif .state == "unmanaged" then
      "accepted today, not yet adopted; the next grant or revoke adopts it"
    else "not granted" end' <<<"$1"
}

tunnel_render_list() { # report
  local report="$1" width name fingerprint sentence machine
  printf 'fleet keys granted SSH access to this machine\n'
  printf '  registry  %s\n' "$(jq -r '.registryPath' <<<"$report")"
  printf '  grants    %s\n' "$(jq -r '.statePath' <<<"$report")"
  printf '  rendered  %s\n\n' "$(jq -r '.authorizedKeys' <<<"$report")"
  width="$(jq -r '[.machines[].name | length] | max' <<<"$report")"
  while IFS= read -r machine; do
    name="$(jq -r '.name' <<<"$machine")"
    fingerprint="$(jq -r '.fingerprint' <<<"$machine")"
    sentence="$(tunnel_state_sentence "$machine")"
    printf '  %-*s  %s  %s\n' "$width" "$name" "$fingerprint" "$sentence"
  done < <(jq -c '.machines[]' <<<"$report")
}

cmd_tunnel() {
  local action="${1:-}"
  case "$action" in
    list | grant | revoke) shift ;;
    *) die "$EX_USAGE" "tunnel expects list, grant, or revoke" ;;
  esac

  if [[ "$action" == list ]]; then
    local json=0
    if [[ "${1:-}" == --json ]]; then
      json=1
      shift
    fi
    [[ $# == 0 ]] || die "$EX_USAGE" "tunnel list accepts only --json"
    local report
    report="$(tunnel_report_json)"
    if [[ "$json" == 1 ]]; then
      printf '%s\n' "$report"
    else
      tunnel_render_list "$report"
    fi
    return
  fi

  local name="" duration=8h
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --for)
        [[ "$action" == grant ]] || die "$EX_USAGE" "tunnel revoke takes no --for"
        duration="${2:?tunnel grant --for expects a duration}"
        shift 2
        ;;
      -*) die "$EX_USAGE" "unknown tunnel $action option: $1" ;;
      *)
        [[ -z "$name" ]] || die "$EX_USAGE" "tunnel $action expects exactly one machine name"
        name="$1"
        shift
        ;;
    esac
  done
  [[ -n "$name" ]] || die "$EX_USAGE" "tunnel $action expects a machine name"

  local fleet primary=0
  fleet="$(tunnel_registry_json)"
  jq -e --arg name "$name" 'any(.[]; .name == $name)' <<<"$fleet" >/dev/null ||
    die "$EX_NOINPUT" "$name is not in home/ssh-fleet-keys; register it through a reviewed commit first"
  ! jq -e --arg name "$name" 'any(.[]; .name == $name and .primary)' <<<"$fleet" >/dev/null ||
    primary=1

  # Refused before the vault is ever touched: the primary key exists so a
  # machine reachable only over SSH cannot be locked out by one keystroke, and
  # an unlock prompt would suggest the refusal is negotiable.
  if [[ "$action" == revoke && "$primary" == 1 ]]; then
    die "$EX_USAGE" "$name is the primary fleet key and can never be revoked here; move the primary role in home/ssh-fleet-keys through a reviewed commit instead"
  fi

  local seconds now expires report
  tunnel_vault_gate
  tunnel_adopt_existing_grants "$fleet"
  if [[ "$action" == revoke ]]; then
    tunnel_state_apply revoke "$name"
    printf 'atyrode: revoked %s\n' "$name" >&2
  elif [[ "$primary" == 1 ]]; then
    printf 'atyrode: %s is the primary fleet key and is always granted\n' "$name" >&2
  else
    seconds="$(tunnel_duration_seconds "$duration")"
    if [[ "$seconds" == 0 ]]; then
      tunnel_state_apply grant "$name" null
      printf 'atyrode: granted %s until revoked\n' "$name" >&2
    else
      now="$(date -u +%s)"
      expires=$((now + seconds))
      tunnel_state_apply grant "$name" "$expires"
      printf 'atyrode: granted %s for %s; sshd stops accepting it at %s\n' \
        "$name" "$duration" "$(date -d "@$expires" +'%Y-%m-%d %H:%M %Z')" >&2
    fi
  fi
  # Bound to a variable first: errexit stops a failed report here instead of
  # handing tunnel_render an empty string.
  report="$(tunnel_report_json)"
  tunnel_render "$report" "$fleet"
  tunnel_vault_cleanup
  trap - EXIT HUP INT TERM
}
