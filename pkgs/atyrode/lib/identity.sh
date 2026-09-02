# shellcheck shell=bash
#
# The machine identity: the age key this machine decrypts clan's vars with,
# and its registration with clan (ADR 0008 step 3, amended: clan is the fleet
# layer).
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# Two identities exist and this module only ever handles one of them. The
# operator's key edits secrets and lives in the Mac's Secure Enclave
# (operator.sh); it is never read here. The machine's key is generated on the
# machine, stays on the machine, and is named to sops-nix in
# modules/shared/clan-machine.nix, so the path below and the one Nix
# evaluates are the same fact written twice -- keep them so. Clan's own flow
# would mint the key on the operator's machine and copy it over SSH; the
# fleet takes the path clan tolerates instead, and clan records only the
# public half.
#
# A clan machine is a system-owned host: nix-darwin or NixOS, activating as
# root, which is why the key is root's and lives where only root can hold it.
# A standalone Home Manager host is invisible to clan and reads no secret, so
# it has no identity to make.
identity_clan_machine() { # activation
  [[ "$1" != home-manager ]]
}

identity_machine_class() { # activation
  if [[ "$1" == nix-darwin ]]; then printf 'darwin\n'; else printf 'nixos\n'; fi
}

# The absolute paths below belong to root and to the machine, which a build
# sandbox is neither of; a check relocates them under a scratch root through
# this seam and nothing else changes.
identity_system_root() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_IDENTITY_ROOT:-}" ]]; then
    printf '%s' "$_ATYRODE_TEST_IDENTITY_ROOT"
  fi
}

identity_key_file() {
  printf '%s/var/lib/sops-nix/key.txt\n' "$(identity_system_root)"
}

# Where the machine publishes its public recipient. Root holds the key under
# a mode-700 directory, so a doctor run by the user could not derive the
# recipient from it without a password prompt; the recipient is public by
# definition, so the ceremony writes it here once, world-readable, and every
# later reader stays silent.
identity_recipient_file() {
  printf '%s/etc/atyrode/machine.pub\n' "$(identity_system_root)"
}

# The age-keygen this build resolves, by path: the privileged calls below run
# under sudo, whose PATH is not this wrapper's, so the announced argv has to
# carry the program the user side actually found.
identity_keygen_program() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_AGE_KEYGEN:-}" ]]; then
    printf '%s\n' "$ATYRODE_AGE_KEYGEN"
  else
    command -v age-keygen
  fi
}

# This machine's public recipient, or nothing. Silent: a read of the
# published file. Never the private half.
identity_recipient() {
  local file recipient=""
  file="$(identity_recipient_file)"
  [[ ! -r "$file" ]] || recipient="$(head -n 1 "$file")"
  [[ "$recipient" =~ ^age1[0-9a-z]+$ ]] || return 1
  printf '%s\n' "$recipient"
}

# The one command that registers this machine: run in a checkout of this
# repository on the Mac, it writes sops/machines/<host>/key.json, which is
# committed like any other file.
identity_registration_command() { # host recipient
  printf 'clan secrets machines add %s %s\n' "$1" "$2"
}

identity_registration_file() { # host
  printf '%s/machines/%s/key.json\n' "$sops_directory" "$1"
}

# Registered means clan's record of this host names exactly this recipient:
# a key.json under another host is a different machine, and one that names a
# recipient this machine no longer has is a stale registration.
identity_registered() { # host recipient
  local file
  file="$(identity_registration_file "$1")"
  [[ -f "$file" ]] &&
    jq -e --arg recipient "$2" \
      '(if type == "array" then .[] else . end) | select(.type == "age" and .publickey == $recipient)' \
      "$file" >/dev/null 2>&1
}

# Portable profiles are the operator's identity on machines that are not the
# fleet's, and standalone Home Manager hosts are fleet members clan does not
# see: neither reads a secret, so an identity there would be a key with
# nothing to open.
identity_host_json() { # [host]
  local host data
  host="$(resolve_host "${1:-}")"
  data="$(host_json "$host")"
  [[ "$(jq -r '.identityMode // "fixed"' <<<"$data")" == fixed ]] ||
    die "$EX_DATAERR" "$host is a portable profile; it is not a fleet member and clan does not know it"
  identity_clan_machine "$(jq -r '.activation' <<<"$data")" ||
    die "$EX_DATAERR" "$host is not a clan machine: it activates with standalone Home Manager and reads no secret"
  printf '%s\n' "$data"
}

identity_report_json() { # host-json
  local host activation recipient registered=false
  host="$(jq -r '.id' <<<"$1")"
  activation="$(jq -r '.activation' <<<"$1")"
  recipient="$(identity_recipient || true)"
  [[ -z "$recipient" ]] || ! identity_registered "$host" "$recipient" || registered=true
  jq -nc --arg host "$host" --arg activation "$activation" \
    --arg machineClass "$(identity_machine_class "$activation")" \
    --arg keyFile "$(identity_key_file)" \
    --arg recipient "$recipient" --argjson registered "$registered" \
    --arg registration "$([[ -z "$recipient" ]] || identity_registration_command "$host" "$recipient")" \
    '{host:$host,activation:$activation,machineClass:$machineClass,keyFile:$keyFile,
      recipient:(if $recipient == "" then null else $recipient end),
      registered:$registered,
      registration:(if $registration == "" then null else $registration end),
      privateMaterialPrinted:false}'
}

# What the operator does next, said the same way by show, init and the doctor
# probe, so no reader ever learns a different next step.
identity_say_registration() { # host recipient
  say "register it with clan in a checkout of this repository on the Mac, then commit sops/machines/$1/key.json:"
  printf '  %s\n' "$(paint 2 "\$ $(identity_registration_command "$1" "$2")")" >&2
  say "once a generator is declared, clan vars generate $1 encrypts its values to this machine"
}

# The key belongs to root, so every step that touches it is a separate
# announced elevation: the directory, the key, the read-back of the public
# half, and its publication where an unprivileged doctor can find it. The
# temporary file carries the public recipient and nothing else. age-keygen
# creates the key at mode 0600 itself and prints only the public key when
# writing; the read-back asks for the public key alone, so nothing about the
# private half ever reaches the terminal.
identity_generate() { # activation
  local key directory recipient_file program install_program recipient temporary
  key="$(identity_key_file)"
  directory="${key%/*}"
  recipient_file="$(identity_recipient_file)"
  program="$(identity_keygen_program)" || die "$EX_UNAVAILABLE" "age-keygen is unavailable"
  install_program="$(command -v install)"
  [[ "$(id -u)" -eq 0 ]] || command -v sudo >/dev/null 2>&1 ||
    die "$EX_UNAVAILABLE" "the machine identity on a $1 host belongs to root, and sudo is unavailable"
  say "this host activates as root, so the key is root's: each step below elevates and says so"
  run_privileged "$install_program" -d -m 0700 -o root "$directory" ||
    die "$EX_SOFTWARE" "could not create $directory"
  run_privileged "$program" -o "$key" ||
    die "$EX_SOFTWARE" "age-keygen did not write $key"
  recipient="$(run_privileged "$program" -y "$key")" ||
    die "$EX_SOFTWARE" "could not read the public recipient back from $key"
  [[ "$recipient" =~ ^age1[0-9a-z]+$ ]] ||
    die "$EX_SOFTWARE" "age-keygen returned something that is not an age recipient"
  temporary="$(mktemp)"
  printf '%s\n' "$recipient" >"$temporary"
  run_privileged "$install_program" -d -m 0755 -o root "${recipient_file%/*}" &&
    run_privileged "$install_program" -m 0644 -o root "$temporary" "$recipient_file" || {
    rm -f -- "$temporary"
    die "$EX_SOFTWARE" "could not publish the public recipient at $recipient_file"
  }
  rm -f -- "$temporary"
  say "wrote $key (root, mode 0600, directory mode 0700) and published its recipient at $recipient_file"
}

# The doctor probe. Three states and one next step each: no key means the
# ceremony, a key clan does not register means the command that registers
# it, and a registered key means this machine can be given secrets. A host
# clan does not build cannot have one at all.
probe_machine_identity() {
  local host data activation recipient
  host="$(resolve_host)"
  data="$(host_json "$host")"
  activation="$(jq -r '.activation' <<<"$data")"
  if [[ "$(jq -r '.identityMode // "fixed"' <<<"$data")" == runtime ]]; then
    provisioning_check_add machine-identity not-applicable portable-profile \
      "portable profiles are not fleet members and read no secret" ""
    return 0
  fi
  if ! identity_clan_machine "$activation"; then
    provisioning_check_add machine-identity not-applicable not-a-clan-machine \
      "$host activates with standalone Home Manager, which clan does not build, so it reads no secret" ""
    return 0
  fi
  if ! recipient="$(identity_recipient)"; then
    provisioning_unconfigured machine-identity \
      "no machine identity at $(identity_key_file), so this machine cannot receive a secret"
    return 0
  fi
  if ! identity_registered "$host" "$recipient"; then
    provisioning_check_add machine-identity degraded not-registered \
      "clan does not register this machine's recipient (sops/machines/$host/key.json), so no secret is encrypted to it" \
      "in a checkout on the Mac, run: $(identity_registration_command "$host" "$recipient")"
    return 0
  fi
  provisioning_check_add machine-identity ok "" \
    "registered with clan as sops/machines/$host/key.json" ""
}

cmd_identity() {
  local action="" json=0 data host activation key recipient
  while [[ $# -gt 0 ]]; do
    case "$1" in
      show | init)
        [[ -z "$action" ]] || die "$EX_USAGE" "identity accepts one of show or init"
        action="$1"
        ;;
      --json) json=1 ;;
      *) die "$EX_USAGE" "unknown identity option: $1" ;;
    esac
    shift
  done
  [[ -n "$action" ]] || die "$EX_USAGE" "identity expects show or init"
  [[ "$json" == 0 || "$action" == show ]] ||
    die "$EX_USAGE" "identity init announces what it writes; use identity show --json for the record"
  data="$(identity_host_json)"
  host="$(jq -r '.id' <<<"$data")"
  activation="$(jq -r '.activation' <<<"$data")"
  key="$(identity_key_file)"

  if [[ "$action" == show ]]; then
    if [[ "$json" == 1 ]]; then
      identity_report_json "$data"
      return 0
    fi
    if ! recipient="$(identity_recipient)"; then
      say "no machine identity yet for $host; create one with: atyrode identity init"
      return "$EX_UNAVAILABLE"
    fi
    printf '%s\n' "$recipient"
    if identity_registered "$host" "$recipient"; then
      say "registered with clan as sops/machines/$host/key.json"
    else
      identity_say_registration "$host" "$recipient"
    fi
    return 0
  fi

  # init is idempotent: a second run never replaces a key that values may
  # already be encrypted to, it repeats the registration the operator still
  # owes.
  if recipient="$(identity_recipient)"; then
    say "$host already has a machine identity at $key; keeping it"
  else
    identity_generate "$activation"
    recipient="$(identity_recipient)" ||
      die "$EX_SOFTWARE" "the published recipient at $(identity_recipient_file) is not readable"
  fi
  if identity_registered "$host" "$recipient"; then
    say "recipient $recipient is registered with clan as sops/machines/$host/key.json"
  else
    identity_say_registration "$host" "$recipient"
  fi
}
