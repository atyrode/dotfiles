# shellcheck shell=bash
#
# Supervised apply jobs: submission, the worker, and status. A mutating Linux
# Home Manager apply runs as a manager-owned transient unit rather than as a
# child of the invoking shell, so replacing a terminal-hosting service cannot
# end the activation and apply-status reconnects to the durable result.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

apply_job_directory=""

apply_job_progress() {
  [[ -n "$apply_job_directory" ]] || return 0
  write_apply_job_json "$apply_job_directory/running.json" \
    "$(jq --arg step "$1" --argjson index "$STEP_INDEX" --argjson total "$STEP_TOTAL" \
      '. + {state:"working",step:$step,index:$index,total:$total,waitingFor:null}' \
      "$apply_job_directory/running.json")"
}

apply_job_waiting() {
  [[ -n "$apply_job_directory" ]] || return 0
  write_apply_job_json "$apply_job_directory/running.json" \
    "$(jq --arg reason "$1" '. + {state:"waiting",waitingFor:$reason}' \
      "$apply_job_directory/running.json")"
}

apply_job_resumed() {
  [[ -n "$apply_job_directory" ]] || return 0
  write_apply_job_json "$apply_job_directory/running.json" \
    "$(jq '. + {state:"working",waitingFor:null}' "$apply_job_directory/running.json")"
}

apply_job_activated() {
  [[ -n "$apply_job_directory" ]] || return 0
  write_apply_job_json "$apply_job_directory/running.json" \
    "$(jq '. + {activationCompleted:true}' "$apply_job_directory/running.json")"
}
apply_jobs_root() {
  printf '%s/atyrode/apply-jobs\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

apply_systemd_run_command() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_SYSTEMD_RUN:-}" ]]; then
    printf '%s\n' "$ATYRODE_SYSTEMD_RUN"
  else
    command -v systemd-run 2>/dev/null
  fi
}

apply_systemctl_command() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_SYSTEMCTL:-}" ]]; then
    printf '%s\n' "$ATYRODE_SYSTEMCTL"
  else
    command -v systemctl 2>/dev/null
  fi
}

apply_supervision_available() {
  if [[ "$test_hooks" == 1 && -n "${_ATYRODE_TEST_SYSTEMD_AVAILABLE:-}" ]]; then
    [[ "$_ATYRODE_TEST_SYSTEMD_AVAILABLE" == 1 ]]
    return
  fi
  [[ "$(uname -s)" == Linux ]] || return 1
  local systemd_run systemctl
  systemd_run="$(apply_systemd_run_command)" || return 1
  systemctl="$(apply_systemctl_command)" || return 1
  [[ -n "$systemd_run" && -n "$systemctl" ]] || return 1
  "$systemctl" --user show-environment >/dev/null 2>&1
}

write_apply_job_json() {
  local path="$1" value="$2" temp
  temp="$(mktemp "$path.XXXXXX")"
  printf '%s\n' "$value" >"$temp"
  mv -f "$temp" "$path"
}

apply_job_phase() {
  local job_dir="$1" unit="$2" systemctl
  if [[ -f "$job_dir/result.json" ]]; then
    jq -r '.phase' "$job_dir/result.json"
    return
  fi
  systemctl="$(apply_systemctl_command)" || {
    printf 'interrupted\n'
    return
  }
  if "$systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
    if [[ -f "$job_dir/running.json" ]]; then
      jq -r 'if .state == "waiting" then "waiting" else "running" end' "$job_dir/running.json"
    else
      printf 'submitted\n'
    fi
  else
    printf 'interrupted\n'
  fi
}

cmd_apply_status() {
  local job_id="" json=0 cancel=0 root job_dir unit phase progress='{}' systemctl
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
        shift
        ;;
      --cancel)
        cancel=1
        shift
        ;;
      --*) die "$EX_USAGE" "unknown apply-status option: $1" ;;
      *)
        [[ -z "$job_id" ]] || die "$EX_USAGE" "apply-status accepts at most one job"
        job_id="$1"
        shift
        ;;
    esac
  done
  [[ "$cancel" == 0 || -n "$job_id" ]] ||
    die "$EX_USAGE" "cancelling requires an explicit job id: atyrode apply-status JOB --cancel"
  if [[ "$cancel" == 1 ]]; then
    guard_production_mutation apply-status
    start_run_log apply-cancel
  fi
  root="$(apply_jobs_root)"
  if [[ -z "$job_id" ]]; then
    [[ -r "$root/latest" ]] || die "$EX_NOINPUT" "no apply jobs have been submitted"
    job_id="$(cat "$root/latest")"
  fi
  [[ "$job_id" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] ||
    die "$EX_USAGE" "invalid apply job: $job_id"
  job_dir="$root/$job_id"
  [[ -r "$job_dir/metadata.json" ]] || die "$EX_NOINPUT" "unknown apply job: $job_id"
  unit="$(jq -r '.unit' "$job_dir/metadata.json")"
  [[ "$unit" == "atyrode-apply-$job_id.service" || "$unit" == "atyrode-apply.service" ]] ||
    die "$EX_DATAERR" "invalid apply job unit"
  [[ ! -r "$job_dir/running.json" ]] || progress="$(cat "$job_dir/running.json")"
  phase="$(apply_job_phase "$job_dir" "$unit")"
  if [[ "$cancel" == 1 && ! -f "$job_dir/result.json" ]]; then
    # A job-specific unit cannot be reused by a later apply between inspection
    # and stop. Older jobs shared one name, so they cannot be cancelled safely
    # through a historical job id.
    [[ "$unit" == "atyrode-apply-$job_id.service" ]] ||
      die "$EX_UNAVAILABLE" "this older job has a shared unit; inspect it with systemctl --user status atyrode-apply.service before stopping it"
    systemctl="$(apply_systemctl_command)" ||
      die "$EX_UNAVAILABLE" "systemctl is unavailable; the apply job was not cancelled"
    if [[ "$(jq -r '.activationCompleted // false' <<<"$progress")" == true ]]; then
      printf 'atyrode: activation already completed; cancelling the remaining work does not roll it back\n' >&2
    else
      printf 'atyrode: activation is not recorded complete; cancellation may leave a partially activated system\n' >&2
    fi
    run_visible "$systemctl" --user stop "$unit" ||
      die "$EX_UNAVAILABLE" "could not stop apply job $job_id; inspect its status before retrying"
    [[ ! -r "$job_dir/running.json" ]] || progress="$(cat "$job_dir/running.json")"
    if [[ ! -f "$job_dir/result.json" ]]; then
      write_apply_job_json "$job_dir/result.json" \
        "$(jq -nc --arg finishedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson progress "$progress" \
          '{schemaVersion:1,phase:"cancelled",exitCode:130,finishedAt:$finishedAt,
            startedAt:$progress.startedAt,activationCompleted:($progress.activationCompleted // false)}')"
    fi
    phase="$(jq -r '.phase' "$job_dir/result.json")"
  fi
  if [[ "$json" == 1 ]]; then
    if [[ -r "$job_dir/result.json" ]]; then
      jq -nc --slurpfile metadata "$job_dir/metadata.json" \
        --slurpfile result "$job_dir/result.json" \
        --rawfile output "$job_dir/output.log" --arg phase "$phase" --argjson progress "$progress" \
        '$metadata[0] + {phase:$phase,progress:$progress,result:$result[0],output:$output}'
    else
      jq -nc --slurpfile metadata "$job_dir/metadata.json" \
        --rawfile output "$job_dir/output.log" --arg phase "$phase" --argjson progress "$progress" \
        '$metadata[0] + {phase:$phase,progress:$progress,result:null,output:$output}'
    fi
  else
    [[ ! -s "$job_dir/output.log" ]] || cat "$job_dir/output.log"
    printf 'atyrode: apply job %s: %s\n' "$job_id" "$phase" >&2
    jq -r --arg phase "$phase" '
      if .step then "  \(if $phase == "waiting" or $phase == "running" then "step" else "last step" end): \(.index)/\(.total) \(.step)" else empty end,
      if $phase == "waiting" and .waitingFor then "  waiting for: \(.waitingFor)" else empty end,
      if .activationCompleted then "  system activation completed" else empty end
    ' <<<"$progress" >&2
    jq -r 'if (.originTty // "") != "" then "  original terminal: \(.originTty)" else empty end' \
      "$job_dir/metadata.json" >&2
    if [[ "$phase" == waiting || "$phase" == running || "$phase" == submitted ]]; then
      printf '  cancel this job: atyrode apply-status %s --cancel\n' "$job_id" >&2
    fi
  fi
  if [[ -r "$job_dir/result.json" ]]; then
    [[ "$cancel" == 0 || "$phase" != cancelled ]] || return 0
    return "$(jq -r '.exitCode' "$job_dir/result.json")"
  fi
  [[ "$phase" != interrupted ]] ||
    return "$EX_SOFTWARE"
}

run_apply_job_worker() {
  local job_dir="${1:-}"
  shift || true
  local root job_id metadata unit live started_at finished_at status phase result
  root="$(apply_jobs_root)"
  [[ -n "$job_dir" && "$job_dir" == "$root/"* ]] ||
    die "$EX_USAGE" "invalid private apply job directory"
  job_id="${job_dir#"$root/"}"
  [[ "$job_id" =~ ^[0-9]+-[0-9]+-[0-9]+$ && "$job_dir" == "$root/$job_id" ]] ||
    die "$EX_USAGE" "invalid private apply job"
  [[ -r "$job_dir/metadata.json" ]] ||
    die "$EX_NOINPUT" "private apply job metadata is unavailable"
  metadata="$(cat "$job_dir/metadata.json")"
  unit="$(jq -r '.unit' <<<"$metadata")"
  [[ "$unit" == "atyrode-apply-$job_id.service" ]] ||
    die "$EX_DATAERR" "private apply job metadata is invalid"

  apply_job_worker=1
  apply_job_directory="$job_dir"
  live=false
  [[ "$(jq -r '.live' <<<"$metadata")" != true ]] || live=true
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_apply_job_json "$job_dir/running.json" \
    "$(jq -nc --arg startedAt "$started_at" \
      '{schemaVersion:1,startedAt:$startedAt,state:"working",activationCompleted:false}')"
  # apply_config is written for errexit: its command substitutions are
  # unguarded, and the synchronous `atyrode apply` path runs it that way. The
  # subshell inherits this `set +e`, so it must re-enable errexit for itself -
  # otherwise a failed substitution yields an empty string and execution
  # continues, turning an actionable diagnostic into a raw jq error further
  # down (and reporting the job as succeeded). `|| status=$?` cannot replace
  # this: bash propagates errexit suppression into the callee.
  set +e
  if [[ "$live" == true ]]; then
    # The operator's terminal is this job's stdio, so the activation writes to
    # it directly: nh renders as it works and anything the activation asks for
    # (sudo, the vault, the provisioning offers below) reaches the human who
    # started it. Capturing to the log instead is what made those prompts
    # unreachable, so the log carries an account of where the output went
    # rather than a copy of it.
    printf 'atyrode: apply job %s streamed live to the operator terminal; no transcript was captured here\n' \
      "$job_id" >>"$job_dir/output.log"
    (
      set -e
      apply_config "$@"
    )
  else
    (
      set -e
      apply_config "$@"
    ) >>"$job_dir/output.log" 2>&1
  fi
  status="$?"
  set -e
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  phase=failed
  [[ "$status" == 0 ]] && phase=succeeded
  result="$(jq -nc --arg phase "$phase" --arg startedAt "$started_at" \
    --arg finishedAt "$finished_at" --argjson exitCode "$status" \
    --argjson activated "$(jq '.activationCompleted' "$job_dir/running.json")" \
    '{schemaVersion:1,phase:$phase,exitCode:$exitCode,startedAt:$startedAt,finishedAt:$finishedAt,
      activationCompleted:$activated}')"
  write_apply_job_json "$job_dir/result.json" "$result"
  return "$status"
}

submit_apply_job() {
  local root job_id job_dir unit created_at metadata latest_temp self systemd_run systemctl
  local env_name probe_status unreachable live=false submitted=1 status=0 origin_tty=""
  local -a run_args job_argv
  root="$(apply_jobs_root)"
  mkdir -p "$root"
  chmod 700 "$root"
  job_id="$(date -u +%s)-$$-$RANDOM"
  job_dir="$root/$job_id"
  unit="atyrode-apply-$job_id.service"
  mkdir -m 700 "$job_dir"
  : >"$job_dir/output.log"
  chmod 600 "$job_dir/output.log"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A supervised apply an operator is watching gets that operator's terminal
  # (see --pty below), and the worker reads this flag to stream rather than
  # capture. Anything without a terminal on both ends - CI, a pipe, a timer -
  # keeps the detached job whose output apply-status replays.
  ! interactive || live=true
  [[ ! -t 0 ]] || origin_tty="$(tty)"
  metadata="$(jq -nc --arg jobId "$job_id" --arg unit "$unit" \
    --arg createdAt "$created_at" --argjson live "$live" --arg originTty "$origin_tty" \
    '{schemaVersion:1,jobId:$jobId,unit:$unit,createdAt:$createdAt,live:$live,originTty:$originTty}')"
  write_apply_job_json "$job_dir/metadata.json" "$metadata"
  self="$(atyrode_self)" ||
    die "$EX_UNAVAILABLE" "atyrode package wrapper is unavailable"
  systemd_run="$(apply_systemd_run_command)" ||
    die "$EX_UNAVAILABLE" "systemd-run became unavailable while submitting apply"
  systemctl="$(apply_systemctl_command)" ||
    die "$EX_UNAVAILABLE" "systemctl became unavailable while submitting apply"
  if "$systemctl" --user is-active --quiet 'atyrode-apply*.service' 2>/dev/null; then
    die "$EX_UNAVAILABLE" "another apply job is active; inspect it with: atyrode apply-status"
  fi
  if [[ "$live" == true ]]; then
    # --pty gives the unit this terminal, so the activation streams as it runs
    # and every prompt it raises is answerable, while the work still happens in
    # a manager-owned unit rather than in this shell's own cgroup. systemd-run
    # waits for the worker and hands back its status, so there is nothing to
    # poll and nothing to replay: the operator already saw all of it.
    run_args=(
      "$systemd_run" --user --unit="$unit" --collect --quiet --pty
      --description="atyrode apply job $job_id"
    )
  else
    run_args=(
      "$systemd_run" --user --unit="$unit" --collect --quiet
      --service-type=exec
      --description="atyrode apply job $job_id"
    )
  fi
  # PATH is forwarded because WSL appends the Windows interop entries to the
  # session PATH only; the user manager never sees them, so a worker started
  # from its environment cannot resolve winget.exe even where the submitting
  # shell resolves it fine. The public wrapper re-prefixes the package's own
  # tools, so forwarding cannot displace them with caller-supplied binaries.
  for env_name in PATH XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME \
    ATYRODE_HOST ATYRODE_GIT_AUTH_MODE SSH_AUTH_SOCK WSL_INTEROP WSLPATH; do
    [[ -z "${!env_name:-}" ]] ||
      run_args+=("--setenv=$env_name=${!env_name}")
  done
  # Publish the job now that it is about to run: a live job hands its terminal
  # away and never gets back here in time to name itself, and a job whose
  # submission fails is exactly the one the operator is told to inspect by id.
  # Later than this is too late, and earlier would let a submission refused for
  # overlapping steal the running job's name.
  latest_temp="$(mktemp "$root/.latest.XXXXXX")"
  printf '%s\n' "$job_id" >"$latest_temp"
  mv -f "$latest_temp" "$root/latest"
  job_argv=("$self" __apply-job "$job_dir" "$@")
  # Everything after this line runs in a manager-owned unit rather than in this
  # shell's cgroup, so a closed terminal or a dropped SSH session cannot kill a
  # half-finished activation. On a terminal the unit borrows this terminal
  # (--pty), so what follows still looks and answers exactly like a local run --
  # which is precisely why the handoff has to be announced rather than inferred
  # from a prompt arriving from somewhere the operator cannot see.
  #
  # Announced in prose, not as argv. This one command carries the machine's
  # whole forwarded PATH: thousands of characters nobody would retype, and a
  # snapshot of an environment a later operator would not want anyway. It is
  # the one place where printing the command would hide what happened instead
  # of showing it. The terminal gets the fact that matters -- which unit owns
  # this apply now -- and the log gets the argv, where length costs nothing and
  # a diagnosis wants every byte.
  log_event "handoff: $(printf '%q ' "${run_args[@]}" -- "${job_argv[@]}")"
  if [[ "$live" == true ]]; then
    printf '%s\n' "$(paint 2 \
      "atyrode: this apply runs in $unit, holding this terminal; it outlives the terminal, not the other way round")" >&2
    # A live run returns the activation's own status, so a failure here is not
    # evidence the job never started; the worker's own files are.
    "${run_args[@]}" -- "${job_argv[@]}" || status=$?
    [[ -e "$job_dir/running.json" || -f "$job_dir/result.json" ]] || submitted=0
  else
    printf '%s\n' "$(paint 2 \
      "atyrode: this apply runs detached in $unit; its output is captured, not streamed")" >&2
    "${run_args[@]}" -- "${job_argv[@]}" || submitted=0
  fi
  if [[ "$submitted" == 0 ]]; then
    write_apply_job_json "$job_dir/result.json" \
      "$(jq -nc --arg createdAt "$created_at" \
        '{schemaVersion:1,phase:"failed",exitCode:69,startedAt:$createdAt,
          finishedAt:$createdAt,error:"systemd-run submission failed"}')"
    die "$EX_UNAVAILABLE" "could not submit apply job $job_id; inspect it with: atyrode apply-status $job_id"
  fi
  if [[ "$live" == true ]]; then
    if [[ -f "$job_dir/result.json" ]]; then
      return "$(jq -r '.exitCode' "$job_dir/result.json")"
    fi
    # The terminal the job was streaming to is gone or the worker died with it,
    # so there is no transcript to hand back - only the journal has one.
    printf 'atyrode: apply job %s stopped without publishing a result; inspect: journalctl --user -u %s\n' \
      "$job_id" "$unit" >&2
    [[ "$status" != 0 ]] || status="$EX_SOFTWARE"
    return "$status"
  fi
  printf 'atyrode: apply job %s submitted; reconnect with: atyrode apply-status %s\n' \
    "$job_id" "$job_id" >&2

  # systemctl separates answers from failures to answer: 0 active, 3 inactive,
  # 4 no such unit, and 1 when the query itself failed. A live worker reports 1
  # exactly like a dead one whenever the user bus cannot answer - which is what
  # activation does to it - so reading any non-zero status as death abandons a
  # running apply and reports the machine's state as unknown when it is fine.
  unreachable=0
  while [[ ! -f "$job_dir/result.json" ]]; do
    if "$systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
      probe_status=0
    else
      probe_status=$?
    fi
    case "$probe_status" in
      0) unreachable=0 ;;
      3 | 4)
        unreachable=0
        sleep 0.1
        if [[ ! -f "$job_dir/result.json" ]]; then
          # The worker died without publishing, so its captured output is the
          # only account of how far the apply got. It is already on disk and
          # apply-status prints it; withholding it here sends the operator to
          # the journal for evidence this command is holding.
          [[ ! -s "$job_dir/output.log" ]] || cat "$job_dir/output.log"
          printf 'atyrode: apply job %s stopped without publishing a result; inspect: journalctl --user -u %s\n' \
            "$job_id" "$unit" >&2
          return "$EX_SOFTWARE"
        fi
        ;;
      *)
        unreachable=$((unreachable + 1))
        if [[ "$unreachable" -ge 300 ]]; then
          printf 'atyrode: lost contact with the user manager while apply job %s ran; it may still be running - reconnect with: atyrode apply-status %s\n' \
            "$job_id" "$job_id" >&2
          return "$EX_UNAVAILABLE"
        fi
        ;;
    esac
    sleep 0.1
  done
  cat "$job_dir/output.log"
  return "$(jq -r '.exitCode' "$job_dir/result.json")"
}
