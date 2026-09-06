# shellcheck shell=bash
#
# Supervised apply jobs: submission, the worker, and status.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# lifecycle reports a deliberately small, named set of operator-owned lifecycle
# artifacts. It never searches HOME: Home Manager's profile, the configured
# dotfiles checkout, OMP's default state/session/worktree roots, and the named
# OMP/atyrode cache/state paths are the entire probe surface. A report is
# advisory only; classifications are conservative and no branch mutates state.
lifecycle_append() {
  local rows="$1" category="$2" path="$3" bytes="$4" evidence="$5" owner="$6" classification="$7" state="$8"
  jq -c --argjson rows "$rows" --arg category "$category" --arg path "$path" \
    --arg evidence "$evidence" --arg owner "$owner" --arg classification "$classification" --arg state "$state" \
    --argjson bytes "$bytes" \
    '$rows + [{category:$category,path:$path,bytes:$bytes,evidence:$evidence,owner:$owner,classification:$classification,state:$state}]' \
    <<<'null'
}

lifecycle_diagnostic() {
  local diagnostics="$1" scope="$2" path="$3" code="$4" message="$5"
  jq -c --argjson diagnostics "$diagnostics" --arg scope "$scope" --arg path "$path" \
    --arg code "$code" --arg message "$message" \
    '$diagnostics + [{scope:$scope,path:$path,code:$code,message:$message}]' <<<'null'
}

lifecycle_bytes() {
  local path="$1" size
  [[ -e "$path" || -L "$path" ]] || {
    printf 'null'
    return
  }
  size="$(du -sb "$path" 2>/dev/null | awk 'NR == 1 { print $1 }')" || true
  [[ "$size" =~ ^[0-9]+$ ]] && printf '%s' "$size" || printf 'null'
}

# Home Manager profile links point into the Nix store. The link's own filesystem
# bytes are not the generation's footprint, so ask Nix for its numeric closure
# size instead. A missing/non-store link or a failed store query is explicitly
# unknown rather than an invented or dereferenced directory size.
lifecycle_generation_bytes() {
  local link="$1" target size
  target="$(readlink -f "$link" 2>/dev/null)" || {
    printf 'null'
    return
  }
  [[ -n "$target" && -e "$target" ]] || {
    printf 'null'
    return
  }
  size="$(nix path-info --json --closure-size "$target" 2>/dev/null |
    jq -er 'to_entries[0].value.closureSize | select(type == "number")' 2>/dev/null)" || true
  [[ "$size" =~ ^[0-9]+$ ]] && printf '%s' "$size" || printf 'null'
}

lifecycle_git_available() {
  local cmd=git
  [[ "$test_hooks" != 1 || -z "${ATYRODE_GIT:-}" ]] || cmd="$ATYRODE_GIT"
  command -v "$cmd" >/dev/null 2>&1
}

lifecycle_git() {
  local cmd=git
  [[ "$test_hooks" != 1 || -z "${ATYRODE_GIT:-}" ]] || cmd="$ATYRODE_GIT"
  "$cmd" "$@"
}

lifecycle_worktree() {
  local rows="$1" diagnostics="$2" category="$3" path="$4" owner="$5" active="$6"
  local bytes classification=protected state=clean status
  bytes="$(lifecycle_bytes "$path")"
  if ! lifecycle_git_available; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" worktree "$path" tool-unavailable "git is unavailable; worktree state is unknown")"
    rows="$(lifecycle_append "$rows" "$category" "$path" "$bytes" "git worktree" "$owner" unknown unknown)"
  elif ! status="$(lifecycle_git -C "$path" status --porcelain 2>/dev/null)"; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" worktree "$path" malformed "cannot read Git worktree state")"
    rows="$(lifecycle_append "$rows" "$category" "$path" "$bytes" "git worktree" "$owner" unknown malformed)"
  else
    [[ -z "$status" ]] || {
      classification=dirty
      state=dirty
    }
    [[ "$active" == 1 && "$classification" == protected ]] && {
      classification=active
      state=active
    }
    rows="$(lifecycle_append "$rows" "$category" "$path" "$bytes" "git status --porcelain" "$owner" "$classification" "$state")"
  fi
  printf '%s\n%s\n' "$rows" "$diagnostics"
}

lifecycle_nix_env_available() {
  local cmd=nix-env
  [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX_ENV:-}" ]] || cmd="$ATYRODE_NIX_ENV"
  command -v "$cmd" >/dev/null 2>&1
}

lifecycle_omp_command() {
  local cmd=omp
  [[ "$test_hooks" != 1 || -z "${ATYRODE_OMP:-}" ]] || cmd="$ATYRODE_OMP"
  printf '%s\n' "$cmd"
}

lifecycle_omp_available() {
  local cmd
  cmd="$(lifecycle_omp_command)"
  command -v "$cmd" >/dev/null 2>&1
}

lifecycle_omp() {
  local cmd
  cmd="$(lifecycle_omp_command)"
  "$cmd" "$@"
}

lifecycle_omp_signal() {
  local signals="$1" kind="$2" value="${3:-}"
  jq -c --argjson signals "$signals" --arg kind "$kind" --arg value "$value" \
    '$signals + [({kind:$kind} + (if $value == "" then {} else {value:$value} end))]' <<<'null'
}

# OMP worktrees are reclaim candidates only when every conservative liveness
# probe is quiet. A dirty Git tree, a branch checked out in the worktree, or an
# explicit activity/lock marker protects the directory. Git probe failures are
# also protected as unknown; this report never turns uncertainty into deletion.
lifecycle_omp_worktree_report() {
  local path="$1" bytes inside="" status="" branch="" git_dir=""
  local classification=reclaimable state=clean git_state=not-a-worktree protected=false
  local signals='[]' marker marker_path
  bytes="$(lifecycle_bytes "$path")"

  if lifecycle_git_available; then
    if inside="$(lifecycle_git -C "$path" rev-parse --is-inside-work-tree 2>/dev/null)" &&
      [[ "$inside" == true ]]; then
      git_state=clean
      if status="$(lifecycle_git -C "$path" status --porcelain 2>/dev/null)"; then
        if [[ -n "$status" ]]; then
          signals="$(lifecycle_omp_signal "$signals" dirty-git-tree)"
          state=dirty
        fi
      else
        git_state=unreadable
        classification=unknown
        state=unknown
        protected=true
      fi
      if branch="$(lifecycle_git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null)" &&
        [[ -n "$branch" ]]; then
        signals="$(lifecycle_omp_signal "$signals" checked-out-branch "$branch")"
      else
        branch=""
      fi
      if git_dir="$(lifecycle_git -C "$path" rev-parse --absolute-git-dir 2>/dev/null)" &&
        [[ -n "$git_dir" ]]; then
        for marker in locked index.lock; do
          marker_path="$git_dir/$marker"
          [[ -e "$marker_path" || -L "$marker_path" ]] || continue
          signals="$(lifecycle_omp_signal "$signals" git-lock-marker "$marker_path")"
        done
      fi
    fi
  else
    git_state=tool-unavailable
    classification=unknown
    state=unknown
    protected=true
  fi

  for marker in .omp-active .active active .activity activity .lock lock; do
    marker_path="$path/$marker"
    [[ -e "$marker_path" || -L "$marker_path" ]] || continue
    case "$marker" in
      .lock | lock) signals="$(lifecycle_omp_signal "$signals" lock-marker "$marker_path")" ;;
      *) signals="$(lifecycle_omp_signal "$signals" activity-marker "$marker_path")" ;;
    esac
  done

  if jq -e 'length > 0' <<<"$signals" >/dev/null; then
    classification=live
    protected=true
    [[ "$state" == dirty ]] || state=active
  fi

  jq -cn --arg path "$path" --argjson bytes "$bytes" --arg classification "$classification" \
    --arg state "$state" --arg gitState "$git_state" --arg branch "$branch" \
    --argjson protected "$protected" --argjson signals "$signals" \
    '{path:$path,bytes:$bytes,classification:$classification,protected:$protected,state:$state,
      gitState:$gitState,branch:(if $branch == "" then null else $branch end),signals:$signals}'
}

lifecycle_omp_worktrees() {
  local root="$1" worktrees='[]' top report
  [[ -d "$root" ]] || {
    printf '[]\n'
    return
  }
  for top in "$root"/*; do
    [[ -d "$top" ]] || continue
    report="$(lifecycle_omp_worktree_report "$top")"
    worktrees="$(jq -c --argjson worktrees "$worktrees" --argjson report "$report" \
      '$worktrees + [$report]' <<<'null')"
  done
  jq -c 'sort_by(.path)' <<<"$worktrees"
}

lifecycle_omp_session_count() {
  local path="$1" count
  [[ -d "$path" ]] || {
    printf '0\n'
    return
  }
  count="$(find "$path" -type f \( -name '*.jsonl' -o -name '*.jsonl.gz' \) -printf '\n' 2>/dev/null |
    awk 'END { print NR + 0 }')" || count=0
  [[ "$count" =~ ^[0-9]+$ ]] && printf '%s\n' "$count" || printf '0\n'
}

# `omp gc` is dry-run by default. `omp worktree clear` is only safe with its
# explicit flag, so keep the argv literal here and expose it in JSON for audit.
# Probe failures are data in the report, never a reason for lifecycle to fail.
lifecycle_omp_dry_runs() {
  local available=false binary="" gc_output="" clear_output=""
  local gc_status=unavailable clear_status=unavailable gc_exit=null clear_exit=null
  if lifecycle_omp_available; then
    available=true
    binary="$(command -v "$(lifecycle_omp_command)")"
    if gc_output="$(lifecycle_omp gc 2>&1)"; then
      gc_status=ok
      gc_exit=0
    else
      gc_exit=$?
      gc_status=error
    fi
    if clear_output="$(lifecycle_omp worktree clear --dry-run 2>&1)"; then
      clear_status=ok
      clear_exit=0
    else
      clear_exit=$?
      clear_status=error
    fi
  fi
  jq -cn --argjson available "$available" --arg binary "$binary" \
    --arg gcStatus "$gc_status" --argjson gcExit "$gc_exit" --arg gcOutput "$gc_output" \
    --arg clearStatus "$clear_status" --argjson clearExit "$clear_exit" --arg clearOutput "$clear_output" \
    '{available:$available,binary:(if $available then $binary else null end),
      gc:{command:["omp","gc"],dryRun:true,status:$gcStatus,exitCode:$gcExit,
        output:(if $available then $gcOutput else null end)},
      worktreeClear:{command:["omp","worktree","clear","--dry-run"],dryRun:true,status:$clearStatus,
        exitCode:$clearExit,output:(if $available then $clearOutput else null end)}}'
}

lifecycle_omp_report() {
  local state_root="$1" sessions="$2" worktree_root="$3" cache="$4"
  local state_state=absent sessions_state=absent worktree_state=absent cache_state=absent
  local state_bytes session_bytes worktree_bytes cache_bytes session_count worktrees dry_runs
  local worktree_count live_count reclaimable_count unknown_count
  [[ -e "$state_root" || -L "$state_root" ]] && state_state=present
  [[ -d "$sessions" ]] && sessions_state=present
  [[ -d "$worktree_root" ]] && worktree_state=present
  [[ -e "$cache" || -L "$cache" ]] && cache_state=present
  state_bytes="$(lifecycle_bytes "$state_root")"
  session_bytes="$(lifecycle_bytes "$sessions")"
  worktree_bytes="$(lifecycle_bytes "$worktree_root")"
  cache_bytes="$(lifecycle_bytes "$cache")"
  session_count="$(lifecycle_omp_session_count "$sessions")"
  worktrees="$(lifecycle_omp_worktrees "$worktree_root")"
  worktree_count="$(jq 'length' <<<"$worktrees")"
  live_count="$(jq '[.[] | select(.classification == "live")] | length' <<<"$worktrees")"
  reclaimable_count="$(jq '[.[] | select(.classification == "reclaimable")] | length' <<<"$worktrees")"
  unknown_count="$(jq '[.[] | select(.classification == "unknown")] | length' <<<"$worktrees")"
  dry_runs="$(lifecycle_omp_dry_runs)"

  jq -cn --arg stateRoot "$state_root" --arg stateState "$state_state" --argjson stateBytes "$state_bytes" \
    --arg sessions "$sessions" --arg sessionsState "$sessions_state" --argjson sessionBytes "$session_bytes" \
    --argjson sessionCount "$session_count" --arg worktreeRoot "$worktree_root" \
    --arg worktreeState "$worktree_state" --argjson worktreeBytes "$worktree_bytes" \
    --argjson worktreeCount "$worktree_count" --argjson liveCount "$live_count" \
    --argjson reclaimableCount "$reclaimable_count" --argjson unknownCount "$unknown_count" \
    --arg cache "$cache" --arg cacheState "$cache_state" --argjson cacheBytes "$cache_bytes" \
    --argjson worktrees "$worktrees" --argjson dryRuns "$dry_runs" \
    '{stateRoot:{path:$stateRoot,bytes:$stateBytes,state:$stateState},
      sessions:{path:$sessions,bytes:$sessionBytes,count:$sessionCount,state:$sessionsState},
      worktreeRoot:{path:$worktreeRoot,bytes:$worktreeBytes,count:$worktreeCount,state:$worktreeState,
        classifications:{live:$liveCount,reclaimable:$reclaimableCount,unknown:$unknownCount}},
      worktrees:$worktrees,caches:[{path:$cache,bytes:$cacheBytes,state:$cacheState}],
      dryRuns:$dryRuns,mutationBoundary:"read-only; omp gc default dry-run; omp worktree clear --dry-run"}'
}

lifecycle_print_omp() {
  local report="$1" output
  jq -r '
    "omp-state-root: \(.stateRoot.state) \(.stateRoot.path) [bytes: \(if .stateRoot.bytes == null then "unknown" else (.stateRoot.bytes|tostring) end)]",
    "omp-sessions: \(.sessions.state) \(.sessions.path) [count: \(.sessions.count); bytes: \(if .sessions.bytes == null then "unknown" else (.sessions.bytes|tostring) end)]",
    "omp-worktree-root: \(.worktreeRoot.state) \(.worktreeRoot.path) [count: \(.worktreeRoot.count); live: \(.worktreeRoot.classifications.live); reclaimable: \(.worktreeRoot.classifications.reclaimable); unknown: \(.worktreeRoot.classifications.unknown); bytes: \(if .worktreeRoot.bytes == null then "unknown" else (.worktreeRoot.bytes|tostring) end)]",
    (.worktrees[] | "omp-worktree: \(.classification) \(.path) [protected: \(.protected); state: \(.state); bytes: \(if .bytes == null then "unknown" else (.bytes|tostring) end); signals: \([.signals[].kind] | join(","))]"),
    (.caches[] | "omp-cache: \(.state) \(.path) [bytes: \(if .bytes == null then "unknown" else (.bytes|tostring) end)]")
  ' <<<"$report"
  if jq -e '.dryRuns.available' <<<"$report" >/dev/null; then
    printf 'omp gc (default dry-run): %s\n' "$(jq -r '.dryRuns.gc.status' <<<"$report")"
    output="$(jq -r '.dryRuns.gc.output // empty' <<<"$report")"
    [[ -z "$output" ]] || printf '%s\n' "$output"
    printf 'omp worktree clear --dry-run: %s\n' "$(jq -r '.dryRuns.worktreeClear.status' <<<"$report")"
    output="$(jq -r '.dryRuns.worktreeClear.output // empty' <<<"$report")"
    [[ -z "$output" ]] || printf '%s\n' "$output"
  else
    printf 'omp dry-runs: unavailable (filesystem-only report)\n'
  fi
}

cmd_lifecycle() {
  local json=0 rows='[]' diagnostics='[]' profile line gen current bytes output omp_report
  local repo="$HOME/nix-dotfiles" omp_state="$HOME/.omp" omp_sessions="$HOME/.omp/agent/sessions"
  local omp_worktrees="$HOME/.omp/wt" cache="$HOME/.cache/oh-my-pi"
  local untrusted_state="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/omp-untrusted"
  local seed_state="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/omp-plain-seed"
  [[ "$test_hooks" != 1 || -z "${ATYRODE_LIFECYCLE_REPO:-}" ]] || repo="$ATYRODE_LIFECYCLE_REPO"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;

      *) die "$EX_USAGE" "unknown lifecycle option: $1" ;;
    esac
    shift
  done

  profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
  if [[ ! -e "$profile" && ! -L "$profile" ]]; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" generations "$profile" absent "Home Manager generations profile is absent")"
    rows="$(lifecycle_append "$rows" home-manager-generation-profile "$profile" null "nix-env --list-generations" home-manager unknown absent)"
  elif ! lifecycle_nix_env_available; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" generations "$profile" tool-unavailable "nix-env is unavailable; generations are unknown")"
    rows="$(lifecycle_append "$rows" home-manager-generation-profile "$profile" "$(lifecycle_generation_bytes "$profile")" "nix-env --list-generations" home-manager unknown unknown)"
  elif ! output="$(nix_env -p "$profile" --list-generations 2>/dev/null)"; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" generations "$profile" unreadable "cannot list Home Manager generations")"
    rows="$(lifecycle_append "$rows" home-manager-generation-profile "$profile" "$(lifecycle_generation_bytes "$profile")" "nix-env --list-generations" home-manager unknown unknown)"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]] ]]; then
        gen="${BASH_REMATCH[1]}"
        current=protected
        [[ "$line" == *"(current)"* ]] && current="protected-current"
        rows="$(lifecycle_append "$rows" home-manager-generation "$profile-$gen-link" "$(lifecycle_generation_bytes "$profile-$gen-link")" "nix-env --list-generations" home-manager "$current" present)"
      else
        diagnostics="$(lifecycle_diagnostic "$diagnostics" generations "$profile" malformed "unparseable nix-env generation row")"
        rows="$(lifecycle_append "$rows" home-manager-generation-profile "$profile" "$(lifecycle_generation_bytes "$profile")" "nix-env --list-generations" home-manager unknown malformed)"
      fi
    done <<<"$output"
  fi

  if [[ ! -d "$repo" ]]; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" worktree "$repo" absent "configured native Git checkout is absent")"
    rows="$(lifecycle_append "$rows" git-worktree "$repo" null "git worktree list --porcelain" dotfiles unknown absent)"
  elif ! lifecycle_git_available; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" worktree "$repo" tool-unavailable "git is unavailable; native worktrees are unknown")"
    rows="$(lifecycle_append "$rows" git-worktree "$repo" "$(lifecycle_bytes "$repo")" "git worktree list --porcelain" dotfiles unknown unknown)"
  elif ! output="$(lifecycle_git -C "$repo" worktree list --porcelain 2>/dev/null)"; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" worktree "$repo" malformed "cannot enumerate native Git worktrees")"
    rows="$(lifecycle_append "$rows" git-worktree "$repo" "$(lifecycle_bytes "$repo")" "git worktree list --porcelain" dotfiles unknown malformed)"
  else
    local worktree="" first=1
    while IFS= read -r line; do
      [[ "$line" == worktree\ * ]] || continue
      worktree="${line#worktree }"
      readarray -t pair < <(lifecycle_worktree "$rows" "$diagnostics" git-worktree "$worktree" dotfiles "$first")
      rows="${pair[0]}"
      diagnostics="${pair[1]}"
      first=0
    done <<<"$output"
  fi

  if [[ ! -d "$omp_worktrees" ]]; then
    diagnostics="$(lifecycle_diagnostic "$diagnostics" worktree "$omp_worktrees" absent "OMP worktree root is absent")"
    rows="$(lifecycle_append "$rows" omp-worktree-root "$omp_worktrees" null "OMP v17 worktree root" omp unknown absent)"
  else
    local path
    for path in "$omp_worktrees"/*; do
      [[ -d "$path" ]] || continue
      readarray -t pair < <(lifecycle_worktree "$rows" "$diagnostics" omp-worktree "$path" omp 0)
      rows="${pair[0]}"
      diagnostics="${pair[1]}"
    done
  fi

  for path in "$cache" "$untrusted_state" "$seed_state"; do
    if [[ -e "$path" || -L "$path" ]]; then
      if [[ "$path" == "$cache" ]]; then
        rows="$(lifecycle_append "$rows" omp-cache "$path" "$(lifecycle_bytes "$path")" "explicit OMP cache path" omp disposable cache)"
      else
        rows="$(lifecycle_append "$rows" atyrode-state "$path" "$(lifecycle_bytes "$path")" "explicit atyrode state path" atyrode protected state)"
      fi
    else
      rows="$(lifecycle_append "$rows" "$([[ "$path" == "$cache" ]] && echo omp-cache || echo atyrode-state)" "$path" null "explicit managed path" "$([[ "$path" == "$cache" ]] && echo omp || echo atyrode)" unknown absent)"
    fi
  done

  omp_report="$(lifecycle_omp_report "$omp_state" "$omp_sessions" "$omp_worktrees" "$cache")"

  if [[ "$json" == 1 ]]; then
    jq -cn --argjson entries "$rows" --argjson diagnostics "$diagnostics" --argjson omp "$omp_report" \
      '{schemaVersion:1,entries:($entries | sort_by(.category, .path)),
        diagnostics:($diagnostics | sort_by(.scope, .path, .code)),omp:$omp}'
  else
    printf 'atyrode: lifecycle inventory (read-only)\n'
    jq -r '.[] | select(.category != "omp-worktree" and .category != "omp-worktree-root" and .category != "omp-cache")
      | "\(.category): \(.classification) \(.path) [bytes: \(if .bytes == null then "unknown" else (.bytes|tostring) end); \(.evidence)]"' <<<"$rows"
    lifecycle_print_omp "$omp_report"
    jq -r '.[] | "diagnostic: \(.scope) \(.code) \(.path): \(.message)"' <<<"$diagnostics" >&2
  fi
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
      printf 'running\n'
    else
      printf 'submitted\n'
    fi
  else
    printf 'interrupted\n'
  fi
}

cmd_apply_status() {
  local job_id="" json=0 root job_dir unit phase
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
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
  phase="$(apply_job_phase "$job_dir" "$unit")"
  if [[ "$json" == 1 ]]; then
    if [[ -r "$job_dir/result.json" ]]; then
      jq -nc --slurpfile metadata "$job_dir/metadata.json" \
        --slurpfile result "$job_dir/result.json" \
        --rawfile output "$job_dir/output.log" --arg phase "$phase" \
        '$metadata[0] + {phase:$phase,result:$result[0],output:$output}'
    else
      jq -nc --slurpfile metadata "$job_dir/metadata.json" \
        --rawfile output "$job_dir/output.log" --arg phase "$phase" \
        '$metadata[0] + {phase:$phase,result:null,output:$output}'
    fi
  else
    [[ ! -s "$job_dir/output.log" ]] || cat "$job_dir/output.log"
    printf 'atyrode: apply job %s: %s\n' "$job_id" "$phase" >&2
  fi
  if [[ -r "$job_dir/result.json" ]]; then
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
  [[ "$unit" == "atyrode-apply.service" ]] ||
    die "$EX_DATAERR" "private apply job metadata is invalid"

  apply_job_worker=1
  live=false
  [[ "$(jq -r '.live' <<<"$metadata")" != true ]] || live=true
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_apply_job_json "$job_dir/running.json" \
    "$(jq -nc --arg startedAt "$started_at" '{schemaVersion:1,startedAt:$startedAt}')"
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
    '{schemaVersion:1,phase:$phase,exitCode:$exitCode,startedAt:$startedAt,finishedAt:$finishedAt}')"
  write_apply_job_json "$job_dir/result.json" "$result"
  rm -f "$job_dir/running.json"
  return "$status"
}

submit_apply_job() {
  local root job_id job_dir unit created_at metadata latest_temp self systemd_run systemctl
  local env_name probe_status unreachable live=false submitted=1 status=0
  local -a run_args job_argv
  root="$(apply_jobs_root)"
  mkdir -p "$root"
  chmod 700 "$root"
  job_id="$(date -u +%s)-$$-$RANDOM"
  job_dir="$root/$job_id"
  unit="atyrode-apply.service"
  mkdir -m 700 "$job_dir"
  : >"$job_dir/output.log"
  chmod 600 "$job_dir/output.log"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A supervised apply an operator is watching gets that operator's terminal
  # (see --pty below), and the worker reads this flag to stream rather than
  # capture. Anything without a terminal on both ends - CI, a pipe, a timer -
  # keeps the detached job whose output apply-status replays.
  ! interactive || live=true
  metadata="$(jq -nc --arg jobId "$job_id" --arg unit "$unit" \
    --arg createdAt "$created_at" --argjson live "$live" \
    '{schemaVersion:1,jobId:$jobId,unit:$unit,createdAt:$createdAt,live:$live}')"
  write_apply_job_json "$job_dir/metadata.json" "$metadata"
  self="$(atyrode_self)" ||
    die "$EX_UNAVAILABLE" "atyrode package wrapper is unavailable"
  systemd_run="$(apply_systemd_run_command)" ||
    die "$EX_UNAVAILABLE" "systemd-run became unavailable while submitting apply"
  systemctl="$(apply_systemctl_command)" ||
    die "$EX_UNAVAILABLE" "systemctl became unavailable while submitting apply"
  if "$systemctl" --user is-active --quiet "$unit" 2>/dev/null; then
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
    ATYRODE_HOST ATYRODE_GIT_AUTH_MODE SSH_AUTH_SOCK; do
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
