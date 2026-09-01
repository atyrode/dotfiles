# shellcheck shell=bash
#
# Opt-in surfaces a machine can be missing, the ledger of what an operator
# declined, and the ceremonies that configure them. Detection and action
# live together because they have to agree.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# --- provisioning surfaces ----------------------------------------------------
# A machine can be fully activated and still be missing things: an archive it
# never configured, a fleet it never enrolled with, a model it never fetched.
# Activation cannot install any of them, because each needs a secret or a
# decision that only the operator can supply. What activation CAN do is stop
# them being invisible.
#
# So every such surface is declared in inventory/provisioning.json and probed
# here. `doctor provisioning` reports them and `apply` acts on them; there is
# one probe set and two consumers, which is what keeps the report and the offer
# from ever disagreeing. Adding a surface is a policy entry plus a probe --
# every machine then heals it on the next apply, with no further wiring.
#
# These are deliberately NOT part of the system boundary. inventory/
# system-boundary.json describes state the machine must have to be correct, and
# `doctor system` fails when it is missing. An unconfigured optional surface is
# not an incorrect machine, so it lives in its own policy with its own family
# and never gates that verdict.

provisioning_checks='[]'

# `jq -e` exits non-zero for a false result, which is a legitimate value here,
# so absence is tested rather than inferred from the exit code.
provisioning_policy_field() { # id field
  local value
  value="$(jq -r --arg id "$1" --arg field "$2" \
    '.surfaces[$id][$field] | if . == null then "" else tostring end' "$provisioning_policy")"
  [[ -n "$value" ]] || die "$EX_SOFTWARE" "inventory/provisioning.json lacks $2 for $1"
  printf '%s\n' "$value"
}

# One line per declined surface, so the file stays something an operator can
# read and edit. The timestamp is for them, never parsed back.
provisioning_ledger() {
  printf '%s/atyrode/provisioning-declined\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

provisioning_declined() { # id
  local ledger
  ledger="$(provisioning_ledger)"
  [[ -f "$ledger" ]] || return 1
  cut -f1 <"$ledger" | grep -Fqx -- "$1"
}

provisioning_record_decline() { # id
  local ledger temporary
  ledger="$(provisioning_ledger)"
  provisioning_declined "$1" && return 0
  mkdir -p "$(dirname "$ledger")"
  temporary="$(mktemp "$(dirname "$ledger")/.provisioning-declined.XXXXXX")"
  [[ ! -f "$ledger" ]] || cat "$ledger" >"$temporary"
  printf '%s\t%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$temporary"
  mv -f "$temporary" "$ledger"
}

# Running the command a decline named is itself a reversal, so provisioning
# clears the record rather than leaving a stale no beside a configured surface.
provisioning_clear_decline() { # id
  local ledger temporary
  ledger="$(provisioning_ledger)"
  [[ -f "$ledger" ]] || return 0
  temporary="$(mktemp "$(dirname "$ledger")/.provisioning-declined.XXXXXX")"
  grep -v "^$1	" <"$ledger" >"$temporary" || true
  mv -f "$temporary" "$ledger"
}

# status is one of:
#   ok             configured and working
#   degraded       configured, but not doing its job; remediation is a fix
#   incomplete     applicable and unconfigured; apply offers the ceremony
#   declined       unconfigured because the operator said no, and it is recorded
#   not-applicable this machine cannot have it at all
# The blocker is a prerequisite command this surface cannot start without. It
# travels as data rather than only as prose because the two readers want
# different things from it: doctor states it, and apply offers to run it.
provisioning_check_add() { # id status code summary remediation [blocker]
  local id="$1" status="$2" code="$3" summary="$4" remediation="$5" blocker="${6:-}"

  provisioning_checks="$(jq -c \
    --arg id "$id" \
    --arg label "$(provisioning_policy_field "$id" label)" \
    --arg command "$(provisioning_policy_field "$id" command)" \
    --arg implies "$(provisioning_policy_field "$id" implies)" \
    --argjson declinable "$(provisioning_policy_field "$id" declinable)" \
    --arg status "$status" \
    --arg code "$code" \
    --arg summary "$summary" \
    --arg remediation "$remediation" \
    --arg blocker "$blocker" \
    '. + [{
      id: $id,
      label: $label,
      command: $command,
      implies: $implies,
      declinable: $declinable,
      status: $status,
      code: (if $code == "" then null else $code end),
      summary: $summary,
      remediation: (if $remediation == "" then null else $remediation end),
      blocker: (if $blocker == "" then null else $blocker end)
    }]' <<<"$provisioning_checks")"
}

# A declined surface reports its decline rather than its absence: the operator
# already answered, and repeating the question as a finding is how a diagnostic
# becomes noise. It is still listed, because "what is missing here" has to
# include the things missing on purpose.
provisioning_unconfigured() { # id summary [blocker]
  if provisioning_declined "$1"; then
    provisioning_check_add "$1" declined declined-by-operator \
      "$2" "reconsider by running the command; that clears the decline"
  else
    provisioning_check_add "$1" incomplete not-configured "$2" "" "${3:-}"
  fi
}

collect_provisioning_checks() {
  provisioning_checks='[]'
  jq -e '.schemaVersion == 1' "$provisioning_policy" >/dev/null ||
    die "$EX_SOFTWARE" "unsupported provisioning policy schema"
  probe_omp_seed
  probe_git_identity
  probe_babel_archive
  probe_local_qwen
  probe_manifold_agent
  jq -e --argjson expected "$(jq -c '.surfaceOrder' "$provisioning_policy")" \
    'map(.id) == $expected' <<<"$provisioning_checks" >/dev/null ||
    die "$EX_SOFTWARE" "provisioning diagnostics do not match the policy order"
}

# Run a provisioning command now, in this terminal, as the operator would type
# it. Re-entering the CLI rather than calling the ceremony in-process is
# deliberate: provisioning owns a vault session, its own traps, and its own
# refusals, and none of them may end an apply that has already activated.
#
# Shown, because it is a whole second program: everything printed after this
# line belongs to that child process, and an operator who wants to run it alone
# needs exactly this argv. Announced by the name the offer just used rather
# than the resolved store path: both start the same program, but only one is
# what an operator types, and a line that disagrees with the question above it
# is worse than no line at all. The resolution goes to the log, which is where
# the exact binary matters.
run_self_visible() { # argv...
  local self
  self="$(atyrode_self)" || return "$EX_UNAVAILABLE"
  show_command atyrode "$@"
  log_event "atyrode resolved to $self"
  "$self" "$@"
}

provision_now() { # target
  run_self_visible provision "$1"
}

# A prerequisite is reached by name, exactly as the ceremonies are: deriving
# argv by splitting the policy string would make the inventory executable, and
# an inventory that can run anything is not an inventory.
provisioning_run_blocker() { # blocker
  case "$1" in
    'atyrode vault login') run_self_visible vault login ;;
    *) die "$EX_SOFTWARE" "no prerequisite is wired for $1" ;;
  esac
}

# What apply does with each surface, and why the three answers differ:
#
#   incomplete  ask, because the machine is missing something the operator can
#               supply and has not yet been asked about on this machine
#   degraded    tell, because it is configured and broken -- there is no yes/no
#               to offer, only a fix to name
#   declined    say nothing; they already answered
#
# Always non-fatal. A machine that declines every surface is still a machine
# that activated successfully, and apply must not imply otherwise.
review_provisioning() { # json host
  local json="$1" host="$2" count index status acted=0 tally leftovers

  collect_provisioning_checks
  count="$(jq -r 'length' <<<"$provisioning_checks")"
  step_why "inventory/provisioning.json declares $count surfaces for this machine"
  index=0
  while ((index < count)); do
    status="$(jq -r ".[$index].status" <<<"$provisioning_checks")"
    case "$status" in
      degraded)
        review_degraded_surface "$json" "$index"
        acted=1
        ;;
      incomplete)
        review_incomplete_surface "$index" "$host"
        acted=1
        ;;
    esac
    index=$((index + 1))
  done
  # Re-probe rather than assume: the verdict has to describe the machine as it
  # is now, not as it was before a ceremony ran. Only worth the second pass when
  # something actually acted -- an untouched machine already has its answer.
  [[ "$acted" == 0 ]] || collect_provisioning_checks
  # Settled first, outstanding last, so the tail of the line is the part that
  # still wants an operator. Alphabetical order would bury it in the middle.
  tally="$(jq -r '
    ["ok","not-applicable","declined","degraded","incomplete"]
    | map(. as $status | {$status, n: ([$provisioning[] | select(.status == $status)] | length)})
    | map(select(.n > 0) | "\(.n) \(.status)") | join(", ")
  ' --argjson provisioning "$provisioning_checks" -n)"
  leftovers="$(jq -r '
    map(select(.status == "incomplete" or .status == "degraded") | .id) | join(", ")
  ' <<<"$provisioning_checks")"
  step_ok "$tally${leftovers:+ -- still to configure: $leftovers}"
  return 0
}

review_degraded_surface() { # json index
  local json="$1" id summary remediation

  id="$(jq -r ".[$2].id" <<<"$provisioning_checks")"
  summary="$(jq -r ".[$2].summary" <<<"$provisioning_checks")"
  remediation="$(jq -r ".[$2].remediation // empty" <<<"$provisioning_checks")"
  printf '%s: %s\n' "$id" "$summary" >&2
  # Seed drift is the one surface whose remediation is itself a review: running
  # it asks the questions rather than answering them, so on a terminal it runs
  # instead of being quoted. Every other fix is a command to type.
  #
  # Shown before it runs for the same reason as any other: the next thing on
  # this terminal is an interactive dialogue from another program, and an
  # operator should never be prompted by something they did not see start.
  if [[ "$id" == omp-seed && "$json" == 0 && "${ATYRODE_SEED_REVIEW:-1}" == 1 ]] && interactive; then
    run_visible atyrode-omp-seed resolve || true
    return 0
  fi
  [[ -z "$remediation" ]] || printf '  fix with: %s\n' "$remediation" >&2
}

# The offer names the command it runs, so accepting here and typing it later
# cannot leave the machine in two different states. Off a terminal the same
# facts are printed without a question, because there is nobody to answer it.
review_incomplete_surface() { # index host
  local id label surface_command implies declinable summary blocker

  id="$(jq -r ".[$1].id" <<<"$provisioning_checks")"
  label="$(jq -r ".[$1].label" <<<"$provisioning_checks")"
  surface_command="$(jq -r ".[$1].command" <<<"$provisioning_checks")"
  implies="$(jq -r ".[$1].implies" <<<"$provisioning_checks")"
  declinable="$(jq -r ".[$1].declinable" <<<"$provisioning_checks")"
  summary="$(jq -r ".[$1].summary" <<<"$provisioning_checks")"
  blocker="$(jq -r ".[$1].blocker // empty" <<<"$provisioning_checks")"

  printf '%s is not configured: %s\n' "$label" "$summary" >&2
  printf '  %s\n' "$implies" >&2
  if ! interactive; then
    printf '  configure with: %s\n' "$surface_command" >&2
    return 0
  fi
  # A prerequisite is something to offer, not homework to set. Telling an
  # operator at a terminal to go and type a command this CLI owns wastes the
  # one moment they are here to answer, and the ceremony would only fail on it
  # again. Asked separately from the surface because declining it makes the
  # surface question moot, and because two surfaces can share one prerequisite:
  # answering yes once settles it for whatever asks next.
  if [[ -n "$blocker" ]]; then
    if ! confirm "$label needs $blocker first; run it now?"; then
      printf '  skipped; %s stays unconfigured until %s runs.\n' "$label" "$blocker" >&2
      return 0
    fi
    if ! provisioning_run_blocker "$blocker"; then
      printf '  that did not complete; %s stays unconfigured.\n' "$label" >&2
      printf '  clear what it reported above, then: %s\n' "$surface_command" >&2
      return 0
    fi
  fi
  # The prompt names the machine, not just the command: these ceremonies write
  # a per-machine identity, and an operator with several hosts open should
  # never have to infer which one is asking.
  if ! confirm "run $surface_command for $2 now?"; then
    if [[ "$declinable" == true ]]; then
      provisioning_record_decline "$id"
      printf '  noted; this machine will not be asked again. Run %s to reconsider.\n' \
        "$surface_command" >&2
    else
      printf '  skipped; run %s when you want to.\n' "$surface_command" >&2
    fi
    return 0
  fi
  # The ceremony printed why it stopped, and that reason is the fix. Naming the
  # same argv as "retry" invites an operator to run the identical command and
  # collect the identical failure, so it is named as what it actually is: the
  # command for afterwards, once the blocker the child reported is gone.
  if ! provisioning_run "$id" "$2"; then
    printf '  that did not complete; %s is still unconfigured.\n' "$label" >&2
    printf '  clear what it reported above, then: %s\n' "$surface_command" >&2
    return 0
  fi
  provisioning_clear_decline "$id"
}

# Each ceremony is reached by the command the offer just named. The mapping is
# explicit rather than derived from the command string: a surface whose
# provisioning moves belongs to one line here, not to a parser.
provisioning_run() { # id host
  case "$1" in
    git-identity) provision_now git ;;
    # The registry name, never a re-derived one: the archive can then only be
    # published under the identity apply just activated.
    babel-archive) ATYRODE_HOST="$2" provision_now babel ;;
    local-qwen) "$atyrode_runtime" provision local-qwen ;;
    manifold-agent) cmd_runtime_manifold provision ;;
    *) die "$EX_SOFTWARE" "no provisioning ceremony is wired for $1" ;;
  esac
}

# Arm the hourly archive timer, which the storage ceremony has just earned.
# modules/home/agent-tools.nix gates the timer with a ConditionPathExists on
# Babel's storage document so that an unconfigured machine never pushes on a
# schedule (babel SPEC.md 12, gate 728). systemd evaluates that condition when
# the timer is started, not continuously, so a machine that activated before it
# was configured leaves the timer inactive until something starts it -- and
# without this, that something would be the next login. Starting a running
# timer is a no-op, so this is safe to repeat. A host with no systemd (macOS
# runs the same wrapper from launchd, which needs no arming) has nothing to do
# here, and a failure to arm is reported rather than fatal: the archive is
# configured either way, and the operator is given the one command that fixes
# it.
archive_arm_timer() {
  local systemctl
  local -a arm
  systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" || return 0
  arm=("$systemctl" --user start babel-archive.timer)
  # Announced, then silenced: the argv is what an operator repeats, while
  # systemd's own failure text is replaced below by the line that names the fix.
  show_command "${arm[@]}"
  "${arm[@]}" >/dev/null 2>&1 ||
    printf 'could not arm the hourly archive timer; arm it with: systemctl --user start babel-archive.timer\n' >&2
}

# --- provision ----------------------------------------------------------------
# One-time interactive machine provisioning (#8, operator decision 2026-08-27):
# per-machine Git SSH keys are vault-backed. `provision git` reconciles the
# machine's auth and signing identities against Bitwarden — materializing a
# vault key into agent memory, backing up a pre-vault local key, or
# bootstrapping a brand-new one (generate, store, register with GitHub).
# Default custody is agent-memory: no private file lands on disk; --persist
# writes the 0600 file for machines that must survive agent restarts
# unattended. Public halves are always written (they are the reviewed data).

provision_git_agent_loaded() { # pub_file
  local ssh_add fingerprint
  ssh_add="$(optional_host_command ATYRODE_SSH_ADD ssh-add)" || return 1
  [[ -f "$1" ]] || return 1
  fingerprint="$("$provision_ssh_keygen" -lf "$1" 2>/dev/null | awk '{print $2}')" || return 1
  [[ -n "$fingerprint" ]] || return 1
  "$ssh_add" -l 2>/dev/null | grep -qF "$fingerprint"
}

provision_git_role() { # role private_path item_name persist yes scratch
  local role="$1" private_path="$2" item_name="$3" persist="$4" yes="$5" scratch="$6"
  local public_path="$private_path.pub" matches count material="$scratch/$role.key"
  matches="$scratch/$role-matches.json"
  vault_find_exact_item "$item_name" "$matches"
  count="$(jq -er 'length' "$matches")"

  if [[ "$count" == 1 ]]; then
    [[ "$(jq -er '.[0].type' "$matches")" == 2 ]] ||
      die "$EX_DATAERR" "Bitwarden item '$item_name' exists but is not a Secure Note"
    bw_cli get item "$(jq -er '.[0].id' "$matches")" |
      jq -er '.notes | select(type == "string")' >"$material" ||
      die "$EX_DATAERR" "Bitwarden Secure Note '$item_name' has no text value"
    chmod 600 "$material"
    "$provision_ssh_keygen" -y -f "$material" >"$material.pub" 2>/dev/null ||
      die "$EX_DATAERR" "Bitwarden Secure Note '$item_name' is not a private SSH key"
    if [[ -f "$private_path" ]]; then
      local local_fp vault_fp
      local_fp="$("$provision_ssh_keygen" -lf "$private_path" 2>/dev/null | awk '{print $2}')"
      vault_fp="$("$provision_ssh_keygen" -lf "$material.pub" | awk '{print $2}')"
      [[ "$local_fp" == "$vault_fp" ]] ||
        die "$EX_DATAERR" "the local $role key and Secure Note '$item_name' are different keys; resolve that conflict manually before provisioning"
      printf 'atyrode: %s key matches the vault\n' "$role" >&2
    else
      install -m 644 "$material.pub" "$public_path"
      if [[ "$persist" == 1 ]]; then
        install -m 600 "$material" "$private_path"
        printf 'atyrode: installed the vault-backed %s key at %s\n' "$role" "$private_path" >&2
      fi
    fi
    if ! provision_git_agent_loaded "$public_path"; then
      "$provision_ssh_add" "$material" 2>/dev/null ||
        die "$EX_UNAVAILABLE" "could not load the $role key into the ssh-agent"
      printf 'atyrode: loaded the %s key into the agent\n' "$role" >&2
    fi
    return 0
  fi

  if [[ -f "$private_path" ]]; then
    # Pre-vault key: this machine predates the vault-backed custody decision.
    if [[ "$yes" == 1 ]] || confirm "Back up the existing $role key to Secure Note '$item_name'?"; then
      vault_store_note "$item_name" "$private_path" "$scratch"
    else
      printf 'atyrode: left the %s key device-local (no vault recovery)\n' "$role" >&2
    fi
    if ! provision_git_agent_loaded "$public_path"; then
      "$provision_ssh_add" "$private_path" 2>/dev/null ||
        printf 'atyrode: warning: could not load the %s key into the ssh-agent\n' "$role" >&2
    fi
    return 0
  fi

  # Brand new identity: generate, store first (the vault is the recovery
  # authority — no window where agent memory holds the only copy), register
  # the public half, then load.
  if [[ "$yes" != 1 ]]; then
    confirm "Generate a new $role key for this machine and store it in Secure Note '$item_name'?" ||
      die "$EX_USAGE" "provision git needs the $role key decision"
  fi
  run_visible "$provision_ssh_keygen" -t ed25519 -N "" \
    -C "$(actual_user)@$(manifold_machine_name) git-$role" -f "$material" -q
  vault_store_note "$item_name" "$material" "$scratch"
  install -m 644 "$material.pub" "$public_path"
  if [[ "$persist" == 1 ]]; then
    install -m 600 "$material" "$private_path"
  fi
  "$provision_ssh_add" "$material" 2>/dev/null ||
    die "$EX_UNAVAILABLE" "could not load the new $role key into the ssh-agent"
  local gh_cli register=(ssh-key add "$public_path" --title "$(manifold_machine_name) git-$role")
  [[ "$role" != signing ]] || register+=(--type signing)
  if gh_cli="$(optional_host_command ATYRODE_GH gh)" && show_command "$gh_cli" "${register[@]}" &&
    "$gh_cli" "${register[@]}" >/dev/null 2>&1; then
    printf 'atyrode: registered the %s public key with GitHub\n' "$role" >&2
  else
    printf 'atyrode: register the %s key yourself: gh %s\n' "$role" "${register[*]}" >&2
  fi
}

# provision babel configures this machine's session archive. It is the same
# ceremony `atyrode apply` offers, reachable by name for recovery and for
# inspection with --dry-run; arguments are forwarded, so the override flags stay
# usable. The identity is the registry name -- never the kernel hostname, which
# is the thing a stable archive identity exists to stop mattering -- and it is
# supplied only for a machine that has never been configured, because the
# ceremony reuses a configured machine's own identity and refuses to change it.
provision_babel() {
  [[ -x "$babel_storage_configure" ]] ||
    die "$EX_UNAVAILABLE" "the babel provisioning ceremony is unavailable in this build"
  local config_file host status=0
  config_file="${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json"
  if [[ -f "$config_file" ]]; then
    run_visible "$babel_storage_configure" "$@" || status=$?
  else
    host="$(resolve_host "")"
    run_visible "$babel_storage_configure" --host-id "$host" "$@" || status=$?
  fi
  # Run rather than exec, because the ceremony is only half of configuring this
  # machine: the hourly timer's start condition is the document the ceremony
  # writes, and systemd tests that condition when the timer starts. Arming it
  # here is what stops a machine provisioned by hand from archiving nothing
  # until its next login. Nothing to arm when the ceremony failed or when it
  # only rehearsed (--dry-run writes no document), and the exit status is the
  # ceremony's own so a failure stays a failure.
  if ((status == 0)) && [[ -f "$config_file" ]]; then
    archive_arm_timer
  fi
  return "$status"
}

cmd_provision() {
  local target="${1:-}" persist=0 yes=0
  case "$target" in
    git) ;;
    babel)
      shift
      provision_babel "$@"
      return
      ;;
    *) die "$EX_USAGE" "provision expects git or babel" ;;
  esac
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --persist) persist=1 ;;
      -y | --yes) yes=1 ;;
      *) die "$EX_USAGE" "unknown provision git option: $1" ;;
    esac
    shift
  done
  provision_ssh_keygen="$(optional_host_command ATYRODE_SSH_KEYGEN ssh-keygen)" ||
    die "$EX_UNAVAILABLE" "ssh-keygen is required by provision git"
  provision_ssh_add="$(optional_host_command ATYRODE_SSH_ADD ssh-add)" ||
    die "$EX_UNAVAILABLE" "ssh-add is required by provision git"
  [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]] ||
    die "$EX_UNAVAILABLE" "no ssh-agent socket; apply this configuration and log in again (services.ssh-agent supervises the Linux agent), or start your platform agent"

  local ssh_home="$HOME/.ssh"
  mkdir -p "$ssh_home"
  chmod 700 "$ssh_home"

  local scratch host
  host="$(manifold_machine_name)"
  scratch="$(vault_secure_temp_dir atyrode-provision)"
  provision_cleanup() {
    rm -rf -- "${scratch:-}"
    vault_close_session
  }
  trap provision_cleanup EXIT HUP INT TERM
  vault_open_session 0
  bw_cli sync >/dev/null || die "$EX_UNAVAILABLE" "Bitwarden sync failed"

  provision_git_role auth "$ssh_home/id_ed25519" \
    "Git SSH auth key ($host)" "$persist" "$yes" "$scratch"
  provision_git_role signing "$ssh_home/id_ed25519_git_signing" \
    "Git SSH signing key ($host)" "$persist" "$yes" "$scratch"

  # The reviewed signer set is git-owned data: a new signing key becomes
  # trusted only through a reviewed commit, never through provisioning.
  local signing_public="$ssh_home/id_ed25519_git_signing.pub" key_blob=""
  key_blob="$(awk '{print $2}' "$signing_public" 2>/dev/null || true)"
  if [[ -n "$key_blob" ]] && ! grep -qF "$key_blob" "$managed_git_allowed_signers"; then
    printf 'atyrode: the signing key is not yet in home/git-allowed-signers; add it through a reviewed commit, then apply\n' >&2
  fi
  printf 'atyrode: verify with: atyrode doctor git\n' >&2
}
