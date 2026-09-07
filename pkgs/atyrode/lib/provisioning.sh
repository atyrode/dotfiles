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
# Activation cannot install most of them, because each needs a secret or a
# decision that only the operator can supply. What activation CAN do is stop
# them being invisible.
#
# So every such surface is declared in fleet/provisioning.json and probed
# here. `doctor provisioning` reports them and `apply` acts on them; there is
# one probe set and two consumers, which is what keeps the report and the offer
# from ever disagreeing. Adding a surface is a policy entry plus a probe --
# every machine then heals it on the next apply, with no further wiring.
#
# The generated agent context is the one surface that needs neither secret
# nor decision, so apply renders it itself; its probe is for the machine
# between applies, where the file decays as sessions come and go. The two
# identities need no secret either, but they are offered rather than done:
# the machine's elevates on a system host, the operator's asks the Mac for
# Touch ID, and each key is the one thing on the machine a rebuild cannot
# recreate, so the operator sees it happen once.
#
# These are deliberately NOT part of the system boundary. fleet/
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
  [[ -n "$value" ]] || die "$EX_SOFTWARE" "fleet/provisioning.json lacks $2 for $1"
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
provisioning_check_add() { # id status code summary remediation
  local id="$1" status="$2" code="$3" summary="$4" remediation="$5"
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
    '. + [{
      id: $id,
      label: $label,
      command: $command,
      implies: $implies,
      declinable: $declinable,
      status: $status,
      code: (if $code == "" then null else $code end),
      summary: $summary,
      remediation: (if $remediation == "" then null else $remediation end)
    }]' <<<"$provisioning_checks")"
}

# A declined surface reports its decline rather than its absence: the operator
# already answered, and repeating the question as a finding is how a diagnostic
# becomes noise. It is still listed, because "what is missing here" has to
# include the things missing on purpose.
provisioning_unconfigured() { # id summary
  if provisioning_declined "$1"; then
    provisioning_check_add "$1" declined declined-by-operator \
      "$2" "reconsider by running the command; that clears the decline"
    return 0
  fi
  provisioning_check_add "$1" incomplete not-configured "$2" ""
}

# The doctor probe for the machine's own age key, the one clan vars are
# decrypted with at activation. A host clan does not build cannot have one.
# A placed key is conclusive machine state; otherwise the sops tree this CLI
# was built with -- the published revision, not any checkout lying around on
# the device -- says whether minting or placement is owed.
probe_machine_key() {
  local host data key_status=0
  host="$(resolve_host)"
  data="$(host_json "$host")"
  if [[ "$(jq -r '.identityMode // "fixed"' <<<"$data")" == runtime ]]; then
    provisioning_check_add machine-key not-applicable portable-profile \
      "portable profiles are not fleet members and read no secret" ""
    return 0
  fi
  machine_key_placed || key_status=$?
  case "$key_status" in
    0)
      provisioning_check_add machine-key ok "" \
        "machine key placed; secrets are decrypted at activation" ""
      return 0
      ;;
    2)
      provisioning_check_add machine-key degraded inspection-unavailable \
        "cannot inspect $(machine_key_file); sudo authorization is unavailable, so placement is unknown" ""
      return 0
      ;;
  esac
  if [[ ! -e "$(machine_key_repository_file "$host")" ]]; then
    provisioning_unconfigured machine-key \
      "no machine key published for $host at this CLI's revision; on an operator device run: clan vars generate $host"
    return 0
  fi
  provisioning_check_add machine-key degraded not-placed \
    "the machine key is in the repository but not at $(machine_key_file); atyrode apply places it" \
    "atyrode apply"
}

collect_provisioning_checks() {
  provisioning_checks='[]'
  jq -e '.schemaVersion == 1' "$provisioning_policy" >/dev/null ||
    die "$EX_SOFTWARE" "unsupported provisioning policy schema"
  probe_omp_seed
  probe_machine_key
  probe_operator_identity
  probe_agent_context
  probe_git_identity
  probe_declared_inputs
  probe_babel_archive
  probe_babel_analysis
  probe_omp_auth_broker
  probe_local_qwen
  probe_manifold_agent
  probe_convergence
  jq -e --argjson expected "$(jq -c '.surfaceOrder' "$provisioning_policy")" \
    'map(.id) == $expected' <<<"$provisioning_checks" >/dev/null ||
    die "$EX_SOFTWARE" "provisioning diagnostics do not match the policy order"
}

# Run a provisioning command now, in this terminal, as the operator would type
# it. Re-entering the CLI rather than calling the ceremony in-process is
# deliberate: a ceremony owns its own traps and its own refusals, and none of
# them may end an apply that has already activated.
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

provision_now() { # target argv...
  run_self_visible provision "$@"
}

# Where clever comes from. A workstation rarely carries clever-tools itself,
# so the CLI reaches the copy in its own closure rather than trusting PATH:
# the generated agent context reports whether Clever Cloud has a session
# here, and a probe that only looked at PATH would report "no opinion" on
# exactly the machines that lack the tool. The seam is for checks, which
# cannot log into a real provider.
clever_program() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_CLEVER:-}" ]]; then
    printf '%s\n' "$ATYRODE_CLEVER"
  elif command -v clever >/dev/null 2>&1; then
    printf 'clever\n'
  else
    printf '%s\n' "$babel_clever"
  fi
}

# Whether Clever Cloud has no session here. `clever profile` is the cheapest
# question that needs one. A copy that cannot run at all is not a logged-out
# provider and gets no opinion.
clever_logged_out() {
  local program
  program="$(clever_program)"
  command -v "$program" >/dev/null 2>&1 || return 1
  ! "$program" profile >/dev/null 2>&1
}

# What apply does with each surface, and why the three answers differ:
#
#   incomplete  ask, because the machine is missing something the operator can
#               supply and has not yet been asked about on this machine
#   degraded    tell, because it is configured and broken -- there is no yes/no
#               to offer, only a fix to name
#   declined    say nothing; they already answered
#
# Declining an optional surface is not an activation failure. Accepting a
# ceremony that then fails is an incomplete apply, and must reach its caller.
review_provisioning() { # json host authoring_repo
  local json="$1" host="$2" authoring_repo="$3" count index status acted=0 tally leftovers review_status=0 omp_summary

  collect_provisioning_checks
  count="$(jq -r 'length' <<<"$provisioning_checks")"
  step_why "fleet/provisioning.json declares $count surfaces for this machine"
  index=0
  while ((index < count)); do
    status="$(jq -r ".[$index].status" <<<"$provisioning_checks")"
    case "$status" in
      degraded)
        review_degraded_surface "$json" "$index" || review_status="$EX_UNAVAILABLE"
        acted=1
        ;;
      incomplete)
        review_incomplete_surface "$index" "$host" "$authoring_repo" || review_status="$EX_UNAVAILABLE"
        acted=1
        ;;
    esac
    index=$((index + 1))
  done
  # Re-probe rather than assume: the verdict has to describe the machine as it
  # is now, not as it was before a ceremony ran. Only worth the second pass when
  # something actually acted -- an untouched machine already has its answer.
  [[ "$acted" == 0 ]] || collect_provisioning_checks
  if [[ "$acted" != 0 ]]; then
    omp_summary="$(jq -r '.[] | select(.id == "omp-seed" and .status == "degraded") | .summary' <<<"$provisioning_checks")"
    if [[ -n "$omp_summary" ]]; then
      step_detail "OMP state after review: $omp_summary"
      step_detail 'If reset values returned, restart OMP sessions opened before the managed-settings guard upgrade, then run atyrode-omp-seed resolve again; those sessions can still run the old rollback watcher.'
    fi
  fi
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
  provisioning_leftovers="$leftovers"
  if [[ "$review_status" != 0 ]]; then
    step_fail "$tally${leftovers:+ -- still to configure: $leftovers}"
  elif [[ -n "$leftovers" ]]; then
    step_skip "$tally -- still to configure: $leftovers"
  else
    step_ok "$tally"
  fi
  return "$review_status"
}

review_degraded_surface() { # json index
  local json="$1" id summary remediation code resolve_status=0

  id="$(jq -r ".[$2].id" <<<"$provisioning_checks")"
  summary="$(jq -r ".[$2].summary" <<<"$provisioning_checks")"
  remediation="$(jq -r ".[$2].remediation // empty" <<<"$provisioning_checks")"
  code="$(jq -r ".[$2].code // empty" <<<"$provisioning_checks")"
  printf '%s: %s\n' "$id" "$summary" >&2
  # Seed drift is the one surface whose remediation is itself a review: running
  # it asks the questions rather than answering them, so on a terminal it runs
  # instead of being quoted. Every other fix is a command to type.
  #
  # Shown before it runs for the same reason as any other: the next thing on
  # this terminal is an interactive dialogue from another program, and an
  # operator should never be prompted by something they did not see start.
  if [[ "$id" == omp-seed && "$code" == seed-drift && "$json" == 0 && "${ATYRODE_SEED_REVIEW:-1}" == 1 ]] && interactive; then
    apply_job_waiting "Review OMP local settings"
    run_visible atyrode-omp-seed resolve || resolve_status=$?
    apply_job_resumed
    return "$resolve_status"
  fi
  [[ -z "$remediation" ]] || printf '  fix with: %s\n' "$remediation" >&2
}

# The offer names the command it runs, so accepting here and typing it later
# cannot leave the machine in two different states. Off a terminal the same
# facts are printed without a question, because there is nobody to answer it.
#
# The machine-key ceremony writes into a checkout, and the only checkout this
# apply can vouch for is the one it built from. An apply of the published
# revision has none, so it names what the command needs rather than picking a
# directory on the operator's behalf -- and it never re-mints: the key is
# either published at this revision or it is not.
review_incomplete_surface() { # index host authoring_repo
  local id label surface_command implies declinable summary

  id="$(jq -r ".[$1].id" <<<"$provisioning_checks")"
  label="$(jq -r ".[$1].label" <<<"$provisioning_checks")"
  surface_command="$(jq -r ".[$1].command" <<<"$provisioning_checks")"
  implies="$(jq -r ".[$1].implies" <<<"$provisioning_checks")"
  declinable="$(jq -r ".[$1].declinable" <<<"$provisioning_checks")"
  summary="$(jq -r ".[$1].summary" <<<"$provisioning_checks")"

  printf '%s is not configured: %s\n' "$label" "$summary" >&2
  printf '  %s\n' "$implies" >&2
  # The policy names the ceremony as an operator would type it, with `--repo
  # PATH` left for them to fill; when this apply built from a checkout, that
  # checkout fills it, and the offer runs exactly the line it shows.
  if [[ "$id" == machine-key ]]; then
    if [[ -z "$3" ]]; then
      printf '  configure with: %s\n' "$surface_command" >&2
      printf '  it commits into a checkout of this repository; this apply built the published revision, which is not one, so name the checkout you will push from\n' >&2
      return 0
    fi
    surface_command="${surface_command/--repo PATH/--repo $(printf '%q' "$3")}"
  fi
  if ! interactive; then
    printf '  configure with: %s\n' "$surface_command" >&2
    return 0
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
  if ! provisioning_run "$id" "$2" "$3"; then
    printf '  that did not complete; %s is still unconfigured.\n' "$label" >&2
    printf '  clear what it reported above, then: %s\n' "$surface_command" >&2
    return "$EX_UNAVAILABLE"
  fi
  provisioning_clear_decline "$id"
}

# Each ceremony is reached by the command the offer just named. The mapping is
# explicit rather than derived from the command string: a surface whose
# provisioning moves belongs to one line here, not to a parser. The archive and
# the Git identity have no line: both are clan vars placed by activation, so
# their probes only ever report them as converged or as owed a generation,
# never as an offer.
provisioning_run() { # id host authoring_repo
  case "$1" in
    machine-key) provision_now machine-key --repo "$3" ;;
    operator-identity) run_self_visible operator init ;;
    agent-context) run_self_visible context render ;;
    local-qwen) "$atyrode_runtime" provision local-qwen ;;
    manifold-agent) run_self_visible runtime provision manifold-agent ;;
    *) die "$EX_SOFTWARE" "no provisioning ceremony is wired for $1" ;;
  esac
}

# Mint this machine's age key into a checkout. Clan does the minting and
# encrypts the private half to the admins group, which is why this can only
# run on a device that is a member: any other device is told so rather than
# handed clan's own refusal. Clan commits what it writes, into the checkout
# the operator named -- never one guessed from HOME -- and the operator
# pushes. Both refusals come before anything is written.
provision_machine_key() { # repo
  local host data user recipient checkout state
  host="$(resolve_host)"
  data="$(host_json "$host")"
  [[ "$(jq -r '.identityMode // "fixed"' <<<"$data")" == fixed ]] ||
    die "$EX_DATAERR" "$host is a portable profile; it is not a fleet member and clan does not know it"
  checkout="$(fleet_repository "$1")"
  user="$(operator_user_for "$host")"
  if ! recipient="$(operator_recipient)" || ! operator_registered "$user" "$recipient"; then
    die "$EX_UNAVAILABLE" "this device holds no registered operator key, so it cannot mint a machine key; run on an operator device: clan vars generate $host"
  fi
  state="$(fleet_repository_state "$checkout")"
  say "source: $(fleet_repository_describe "$checkout" "$state")"
  local -a clan_write
  mapfile -t clan_write < <(clan_write_command "$checkout")
  say "clan mints $host's key and encrypts it to group $operator_group; it commits the result, which is then pushed like any other change"
  run_visible "${clan_write[@]}" vars generate "$host" --flake "$checkout" ||
    die "$EX_SOFTWARE" "clan did not generate $host's vars"
  say "review the commit clan made in $checkout, then push it; apply on $host places the key"
}

# Arm the hourly archive timer once activation has placed the storage
# document. modules/home/agent-tools/contract.nix gates the timer with a
# ConditionPathExists on that document so that an unconfigured machine never
# pushes on a schedule (babel SPEC.md 12, gate 728). systemd evaluates the
# condition when the timer is started, not continuously, and the unit itself
# does not change when the document appears, so an activation that placed it
# leaves the timer inactive until something starts it -- and without this,
# that something would be the next login. Starting a running timer is a
# no-op, so this is safe to repeat. A host with no systemd (macOS runs the
# same wrapper from launchd) has nothing to arm.
archive_arm_timer() {
  local systemctl
  local -a arm
  systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)" || return 0
  arm=("$systemctl" --user start babel-archive.timer)
  # Keep the service's real error alongside the command that retries arming.
  show_command "${arm[@]}"
  if ! "${arm[@]}"; then
    printf 'could not arm the hourly archive timer; arm it with: systemctl --user start babel-archive.timer\n' >&2
    return "$EX_UNAVAILABLE"
  fi
}

# The apply step around it: nothing to arm on a machine whose document is not
# placed yet, and that machine is told which device owes the generation.
archive_converge_timer() { # host
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json" ]]; then
    if archive_arm_timer; then
      step_ok
    else
      step_fail 'the hourly archive timer was not armed'
      return "$EX_UNAVAILABLE"
    fi
  else
    step_skip "no storage document placed yet (clan vars generate $1 on an operator device, then apply)"
  fi
}

# --- provision ----------------------------------------------------------------
# The one ceremony left to the machine itself: minting its own age key when it
# is also an operator device. Every other value is a clan var generated on an
# operator device and placed by activation.
cmd_provision() {
  case "${1:-}" in
    machine-key)
      shift
      local repo=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --repo)
            [[ $# -ge 2 ]] || die "$EX_USAGE" "--repo requires a path"
            repo="$2"
            shift 2
            ;;
          *) die "$EX_USAGE" "unknown provision machine-key option: $1" ;;
        esac
      done
      provision_machine_key "$repo"
      ;;
    *) die "$EX_USAGE" "provision expects machine-key" ;;
  esac
}
