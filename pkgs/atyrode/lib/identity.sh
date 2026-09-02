# shellcheck shell=bash
#
# The machine identity: the age key this machine decrypts the fleet's secrets
# with, and its registration in the audience file (ADR 0008 step 3).
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# Two identities exist and this module only ever handles one of them. The
# operator's key edits secrets and lives in the Mac's Secure Enclave
# (operator.sh); it is never read here. The machine's key is generated on the
# machine, stays on the machine, and is named to sops-nix in
# modules/secrets.nix, so the path below and the one Nix evaluates are the
# same fact written twice -- keep them so.
#
# On a standalone Home Manager host the key sits in the user's own
# configuration, deliberately not in the `keys.txt` sops reads by default: on
# the operator's workstation that file is the operator identity, and an
# activation must never be able to decrypt as the operator. The system-owned
# kinds activate as root and keep the key where only root can hold it.
identity_key_file() { # activation
  case "$1" in
    home-manager) printf '%s/sops/age/machine.txt\n' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    nix-darwin | nixos | nixos-wsl) printf '/var/lib/sops-nix/machine.txt\n' ;;
    *) die "$EX_SOFTWARE" "no machine identity path is defined for activation $1" ;;
  esac
}

identity_system_owned() { # activation
  [[ "$1" != home-manager ]]
}

# Where a system host publishes its public recipient. Root holds the key
# under a mode-700 directory, so a doctor run by the user could not derive
# the recipient from it without a password prompt; the recipient is public by
# definition and the CLI's marker directory is already world-readable, so
# the ceremony writes it there once and every later reader stays silent.
readonly identity_recipient_file='/etc/atyrode/machine.pub'

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

# This machine's public recipient, or nothing. Silent: a read on the user's
# own key, or of the published file on a system host. Never the private half.
identity_recipient() { # activation
  local key program recipient=""
  key="$(identity_key_file "$1")"
  if identity_system_owned "$1"; then
    [[ ! -r "$identity_recipient_file" ]] || recipient="$(head -n 1 "$identity_recipient_file")"
  elif [[ -e "$key" ]]; then
    program="$(identity_keygen_program)" || return 1
    recipient="$("$program" -y "$key" 2>/dev/null)" || return 1
  fi
  [[ "$recipient" =~ ^age1[0-9a-z]+$ ]] || return 1
  printf '%s\n' "$recipient"
}

# The one line the operator adds to .sops.yaml. The anchor is the host id, so
# the slot the audience file already names is the slot this fills.
identity_registration_line() { # host recipient
  printf -- '- &%s %s\n' "$1" "$2"
}

# Registered means exactly that line, uncommented, in the packaged audience
# file: a recipient under another anchor is a different machine's slot, and
# a commented slot is still empty.
identity_registered() { # host recipient
  grep -Eq "^[[:space:]]*-[[:space:]]*&$1[[:space:]]+$2[[:space:]]*$" "$sops_audience"
}

# Portable profiles are the operator's identity on machines that are not the
# fleet's: they have no slot in the audience file and read no secret, so an
# identity there would be a key with nothing to open.
identity_host_json() { # [host]
  local host data
  host="$(resolve_host "${1:-}")"
  data="$(host_json "$host")"
  [[ "$(jq -r '.identityMode // "fixed"' <<<"$data")" == fixed ]] ||
    die "$EX_DATAERR" "$host is a portable profile; it is not a fleet member and has no slot in .sops.yaml"
  printf '%s\n' "$data"
}

identity_report_json() { # host-json
  local host activation key recipient registered=false
  host="$(jq -r '.id' <<<"$1")"
  activation="$(jq -r '.activation' <<<"$1")"
  key="$(identity_key_file "$activation")"
  recipient="$(identity_recipient "$activation" || true)"
  [[ -z "$recipient" ]] || ! identity_registered "$host" "$recipient" || registered=true
  jq -nc --arg host "$host" --arg activation "$activation" --arg keyFile "$key" \
    --arg recipient "$recipient" --argjson registered "$registered" \
    --arg line "$([[ -z "$recipient" ]] || identity_registration_line "$host" "$recipient")" \
    '{host:$host,activation:$activation,keyFile:$keyFile,
      recipient:(if $recipient == "" then null else $recipient end),
      registered:$registered,
      registration:(if $line == "" then null else $line end),
      privateMaterialPrinted:false}'
}

# What the operator does next, said the same way by show, init and the doctor
# probe, so no reader ever learns a different next step.
identity_say_registration() { # host recipient
  say "add this line to .sops.yaml under machines, then re-encrypt the files it may read:"
  printf '  %s\n' "$(identity_registration_line "$1" "$2")" >&2
  printf '  %s\n' "$(paint 2 '$ sops updatekeys secrets/shared.yaml')" >&2
  printf '  %s\n' "$(paint 2 "\$ sops updatekeys secrets/$1.yaml")" >&2
}

# The key is generated in place by age-keygen, which creates the file at
# mode 0600 itself; the modes are then asserted rather than trusted, because
# a key that was readable for even a moment is a key to rotate. Nothing about
# the private half ever reaches the terminal: age-keygen prints only the
# public key when writing, and the read-back below asks for the public key
# alone.
identity_generate_user() { # key
  local key="$1" directory="${1%/*}" program
  program="$(identity_keygen_program)" || die "$EX_UNAVAILABLE" "age-keygen is unavailable"
  mkdir -p "$directory"
  chmod 700 "$directory"
  (umask 077 && run_visible "$program" -o "$key") ||
    die "$EX_SOFTWARE" "age-keygen did not write $key"
  chmod 600 "$key"
  say "wrote $key (mode 0600, directory mode 0700)"
}

# A system host's key belongs to root, so every step that touches it is a
# separate announced elevation: the directory, the key, the read-back of the
# public half, and its publication where an unprivileged doctor can find it.
# The temporary file carries the public recipient and nothing else.
identity_generate_system() { # key
  local key="$1" directory="${1%/*}" program install_program recipient temporary
  program="$(identity_keygen_program)" || die "$EX_UNAVAILABLE" "age-keygen is unavailable"
  install_program="$(command -v install)"
  [[ "$(id -u)" -eq 0 ]] || command -v sudo >/dev/null 2>&1 ||
    die "$EX_UNAVAILABLE" "the machine identity on a $2 host belongs to root, and sudo is unavailable"
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
  run_privileged "$install_program" -d -m 0755 -o root "${identity_recipient_file%/*}" &&
    run_privileged "$install_program" -m 0644 -o root "$temporary" "$identity_recipient_file" || {
    rm -f -- "$temporary"
    die "$EX_SOFTWARE" "could not publish the public recipient at $identity_recipient_file"
  }
  rm -f -- "$temporary"
  say "wrote $key (root, mode 0600, directory mode 0700) and published its recipient at $identity_recipient_file"
}

# The doctor probe. Three states and one next step each: no key means the
# ceremony, a key the audience file does not name means the line to add, and
# a registered key means this machine can be given secrets. A portable
# profile cannot have one at all.
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
  if ! recipient="$(identity_recipient "$activation")"; then
    provisioning_unconfigured machine-identity \
      "no machine identity at $(identity_key_file "$activation"), so this machine cannot receive a secret"
    return 0
  fi
  if ! identity_registered "$host" "$recipient"; then
    provisioning_check_add machine-identity degraded not-registered \
      "this machine's recipient is not in .sops.yaml, so no secret is encrypted to it" \
      "add '$(identity_registration_line "$host" "$recipient")' to .sops.yaml under machines, then run sops updatekeys on the files it may read"
    return 0
  fi
  provisioning_check_add machine-identity ok "" \
    "registered in .sops.yaml as &$host" ""
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
  key="$(identity_key_file "$activation")"

  if [[ "$action" == show ]]; then
    if [[ "$json" == 1 ]]; then
      identity_report_json "$data"
      return 0
    fi
    if ! recipient="$(identity_recipient "$activation")"; then
      say "no machine identity yet for $host; create one with: atyrode identity init"
      return "$EX_UNAVAILABLE"
    fi
    printf '%s\n' "$recipient"
    if identity_registered "$host" "$recipient"; then
      say "registered in .sops.yaml as &$host"
    else
      identity_say_registration "$host" "$recipient"
    fi
    return 0
  fi

  # init is idempotent: a second run never replaces a key that other files
  # may already be encrypted to, it repeats the registration the operator
  # still owes.
  if recipient="$(identity_recipient "$activation")"; then
    say "$host already has a machine identity at $key; keeping it"
  else
    if identity_system_owned "$activation"; then
      identity_generate_system "$key" "$activation"
      recipient="$(identity_recipient "$activation")" ||
        die "$EX_SOFTWARE" "the published recipient at $identity_recipient_file is not readable"
    else
      identity_generate_user "$key"
      recipient="$(identity_recipient "$activation")" ||
        die "$EX_SOFTWARE" "the key at $key did not yield a recipient"
    fi
  fi
  if identity_registered "$host" "$recipient"; then
    say "recipient $recipient is registered in .sops.yaml as &$host"
  else
    identity_say_registration "$host" "$recipient"
  fi
}
