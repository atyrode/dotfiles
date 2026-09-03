# shellcheck shell=bash
#
# The operator identity: the age key this device edits the fleet's secrets
# with, and its registration as a clan user in the admins group (ADR 0008
# step 3, amended: one operator key per device).
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# Every device the operator works from holds its own key and is its own clan
# user, `alex-<host>`, all of them members of the `admins` group that every
# value is encrypted to. No device is special: a key is minted where it is
# used and never copied, so losing a device costs removing one user from the
# group and nothing else. On a Mac the key is minted inside the Secure
# Enclave, because that hardware exists there and makes the key impossible to
# exfiltrate; the file it writes is a handle the enclave understands, not key
# material. Anywhere else it is a plain age identity protected by the account
# alone, which grants exactly the same authority. `alex-recovery` is the
# software key whose only copy is the break-glass note in Bitwarden; it is a
# member of the group from day one so that losing every device costs one
# re-encryption, and nothing here ever reads it.
#
# The key lands in the file sops reads by default, which is also where clan
# looks for the identity that decrypts a machine's key before placing it.
readonly operator_group=admins
readonly operator_recovery_user=alex-recovery

# The clan user name of a device is its registry id, prefixed with the
# operator's name unless the id already carries it.
operator_user_for() { # host
  if [[ "$1" == alex-* ]]; then printf '%s\n' "$1"; else printf 'alex-%s\n' "$1"; fi
}

operator_key_file() {
  printf '%s/sops/age/keys.txt\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Portable profiles are the operator's identity on machines that are not the
# fleet's: they may read the repository but never hold a key to its secrets,
# so the ceremony is applicable on every fixed host and nowhere else.
operator_applicable() { # host-json
  [[ "$(jq -r '.identityMode // "fixed"' <<<"$1")" == fixed ]]
}

operator_platform_darwin() { # host-json
  [[ "$(jq -r '.system' <<<"$1")" == *-darwin ]]
}

# The public half is the `# public key:` line both age-keygen and
# age-plugin-se write above the identity line. It is read rather than derived
# because no program here may be handed the file that could echo the identity
# back: `age-keygen -y` rejects plugin identities outright, and
# `age-plugin-se recipients` would take the whole file on stdin. Silent, and
# never the identity line.
operator_recipient() {
  local key recipient
  key="$(operator_key_file)"
  [[ -r "$key" ]] || return 1
  recipient="$(sed -n 's/^# public key: //p' "$key" | head -n 1)"
  [[ "$recipient" =~ ^age1[0-9a-z]+$ ]] || return 1
  printf '%s\n' "$recipient"
}

# Why there is no usable operator identity, said the same way by show, init
# and the doctor probe. A file without a recipient line is not one this
# ceremony wrote; it is never overwritten and never read past its comment
# lines, the operator moves it aside.
operator_absence() {
  local key
  key="$(operator_key_file)"
  if [[ -e "$key" ]]; then
    printf '%s\n' "$key holds no age recipient line, so it is not a key this ceremony wrote; move the file aside and then run: atyrode operator init"
  else
    printf '%s\n' "no operator key at $key; this device cannot edit a secret, so create one with: atyrode operator init"
  fi
}

# The two commands that register a device: the first records its recipient
# as a clan user, the second makes that user a member of the group every
# value is encrypted to. Run in any checkout of this repository; clan commits
# what they write.
operator_registration_commands() { # user recipient
  printf 'clan secrets users add %s %s\n' "$1" "$2"
  printf 'clan secrets groups add-user %s %s\n' "$operator_group" "$1"
}

# Registered means clan's record of this device names exactly this recipient
# and the user is in the group; a stale recipient is a device that was
# rebuilt without re-enrolling, and a user outside the group can read
# nothing. Clan records membership as a symlink per member under the group.
operator_registered() { # user recipient
  local file="$sops_directory/users/$1/key.json"
  [[ -f "$file" ]] &&
    jq -e --arg recipient "$2" \
      '(if type == "array" then .[] else . end) | select(.type == "age" and .publickey == $recipient)' \
      "$file" >/dev/null 2>&1 &&
    [[ -e "$sops_directory/groups/$operator_group/users/$1" ]]
}

operator_registration_summary() { # user
  printf 'registered with clan as sops/users/%s/key.json (group %s)\n' "$1" "$operator_group"
}

# What the operator does next, said the same way by show, init and the doctor
# probe. Nothing has to be re-encrypted by hand: clan re-keys the group's
# values when a member joins.
operator_say_registration() { # user recipient
  local command
  say "register this device with clan in any checkout of this repository, then commit what it writes under sops/:"
  while IFS= read -r command; do
    printf '  %s\n' "$(paint 2 "\$ $command")" >&2
  done < <(operator_registration_commands "$1" "$2")
}

# The key is written by the generator itself at mode 0600, and the generator
# prints only the public half, on stdout; the modes are then asserted rather
# than trusted. On a Mac the plugin asks the Secure Enclave for a new key
# under the given access control, which is what makes macOS prompt for Touch
# ID (or the login passcode) once here and on every later decryption.
operator_generate() { # key host-json
  local key="$1" directory="${1%/*}"
  mkdir -p "$directory"
  chmod 700 "$directory"
  if operator_platform_darwin "$2"; then
    say "macOS will prompt for Touch ID: the key is minted inside the Secure Enclave and never leaves it"
    (umask 077 && tool_exec visible ATYRODE_AGE_PLUGIN_SE age-plugin-se keygen \
      --access-control=any-biometry-or-passcode -o "$key") ||
      die "$EX_SOFTWARE" "age-plugin-se did not write $key"
  else
    say "no Secure Enclave here: the key is a file, protected only by this account"
    (umask 077 && tool_exec visible ATYRODE_AGE_KEYGEN age-keygen -o "$key") ||
      die "$EX_SOFTWARE" "age-keygen did not write $key"
  fi
  chmod 600 "$key"
  say "wrote $key (mode 0600, directory mode 0700)"
}

# The doctor probe. A portable profile has nothing to hold; a fixed host has
# three states and one next step each: no key means the ceremony, a key clan
# does not register means the commands that register it, and a registered
# key means the operator can edit here.
probe_operator_identity() {
  local host data user recipient
  host="$(resolve_host)"
  data="$(host_json "$host")"
  if ! operator_applicable "$data"; then
    provisioning_check_add operator-identity not-applicable portable-profile \
      "portable profiles are not operator devices and hold no key to a secret" ""
    return 0
  fi
  user="$(operator_user_for "$host")"
  if ! recipient="$(operator_recipient)"; then
    provisioning_unconfigured operator-identity "$(operator_absence)"
    return 0
  fi
  if ! operator_registered "$user" "$recipient"; then
    provisioning_check_add operator-identity degraded not-registered \
      "clan does not register this device's key as sops/users/$user/key.json in group $operator_group, so it can edit no secret" \
      "in any checkout, run: $(operator_registration_commands "$user" "$recipient" | sed 'N;s/\n/ \&\& /')"
    return 0
  fi
  provisioning_check_add operator-identity ok "" "$(operator_registration_summary "$user")" ""
}

cmd_operator() {
  local action="" data host user key recipient
  while [[ $# -gt 0 ]]; do
    case "$1" in
      show | init)
        [[ -z "$action" ]] || die "$EX_USAGE" "operator accepts one of show or init"
        action="$1"
        ;;
      *) die "$EX_USAGE" "unknown operator option: $1" ;;
    esac
    shift
  done
  [[ -n "$action" ]] || die "$EX_USAGE" "operator expects show or init"
  host="$(resolve_host)"
  data="$(host_json "$host")"
  operator_applicable "$data" ||
    die "$EX_DATAERR" "$host is a portable profile; it is not an operator device and holds no key to a secret"
  user="$(operator_user_for "$host")"
  key="$(operator_key_file)"

  if [[ "$action" == show ]]; then
    if ! recipient="$(operator_recipient)"; then
      say "$(operator_absence)"
      return "$EX_UNAVAILABLE"
    fi
    printf '%s\n' "$recipient"
    if operator_registered "$user" "$recipient"; then
      say "$(operator_registration_summary "$user")"
    else
      operator_say_registration "$user" "$recipient"
    fi
    return 0
  fi

  # init is idempotent: a second run never replaces a key that files may
  # already be encrypted to and that an enclave could not give back, it
  # repeats the registration the operator still owes.
  if [[ -e "$key" ]]; then
    say "$key already exists; keeping it"
    recipient="$(operator_recipient)" || die "$EX_DATAERR" "$(operator_absence)"
  else
    operator_generate "$key" "$data"
    recipient="$(operator_recipient)" ||
      die "$EX_SOFTWARE" "the key at $key did not yield an age recipient"
  fi
  if operator_registered "$user" "$recipient"; then
    say "recipient $recipient is $(operator_registration_summary "$user")"
  else
    operator_say_registration "$user" "$recipient"
  fi
}
