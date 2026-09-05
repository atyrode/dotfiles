# shellcheck shell=bash
#
# The gate every activation passes: what the switch from the running
# generation to an exact candidate does to services, and whether that may
# happen unattended.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.
#
# On 2026-09-05 a task-scoped edit activated an aggregate generation whose
# unrelated Home Manager change restarted the agent that owned every live
# terminal. Nothing in the diff, the package list or the commit said so; only
# the two closures did. So the closures are what is read, by one analyzer
# (libexec/atyrode-disruption), and its report is the single thing apply,
# rollback, the fleet and the cockpit act on. The report is computed before
# anything is queued for a stop, and an operator's acknowledgement of a
# disruptive report -- `--expected-disruption` -- names the report's
# fingerprint, which binds host, both generations and every effect: a
# different candidate, a generation switched underneath, or one more affected
# service and the acknowledgement no longer applies. There is no flag that
# says "yes to whatever this turns out to be".

# Where the generation this machine runs lives, per activation owner. The
# system owners publish /run/current-system; standalone Home Manager compares
# against the gcroot its own activation reads. A first activation has nothing
# to compare against and reports an empty path, which the analyzer treats as
# "every unit is new". That is only true when nothing was activated before:
# a machine with no system link but a Home Manager gcroot ran standalone
# Home Manager, whose agents its first embedded activation would replace
# under a report saying nothing runs, and a Home Manager profile whose gcroot
# is gone is not a first activation either. Both are baselines that cannot be
# named, and that is a failure rather than an empty answer.
current_generation() { # activation user
  local gcroot
  gcroot="$(home_manager_gcroot "$2")"
  case "$1" in
    nixos | nixos-wsl | nix-darwin)
      local link=/run/current-system
      [[ "$test_hooks" != 1 || -z "${_ATYRODE_TEST_CURRENT_SYSTEM:-}" ]] || link="$_ATYRODE_TEST_CURRENT_SYSTEM"
      if [[ -e "$link" ]]; then
        readlink -f "$link"
        return 0
      fi
      [[ ! -e "$gcroot" ]] || {
        printf 'atyrode: %s does not exist but %s does: this machine ran standalone Home Manager, and the generation its agents would be switched from cannot be named\n' \
          "$link" "$gcroot" >&2
        return 1
      }
      ;;
    home-manager)
      local profile
      if [[ -e "$gcroot" ]]; then
        readlink -f "$gcroot"
        return 0
      fi
      profile="$(gen_profile)"
      [[ ! -e "$profile" ]] || {
        printf 'atyrode: %s exists but %s does not, so the generation Home Manager would switch from cannot be named\n' \
          "$profile" "$gcroot" >&2
        return 1
      }
      ;;
  esac
}

# Home Manager's own record of what it last activated for an account. The
# account is named rather than assumed from $HOME, because a NixOS rollback
# runs under sudo with root's HOME and must still find the operator's.
home_manager_gcroot() { # user
  local home="$HOME"
  if [[ -n "$1" && "$1" != "$(actual_user)" && "$1" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    home="$(eval "printf '%s' ~$1")"
  fi
  if [[ "$home" == "$HOME" ]]; then
    printf '%s/home-manager/gcroots/current-home\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
  else
    printf '%s/.local/state/home-manager/gcroots/current-home\n' "$home"
  fi
}

# The GC-rooted link a candidate is built to: one per invocation, so a preview
# or dry run for the same host -- which holds no lock -- can never rewrite
# the link a locked apply is about to read and activate. The link is removed
# once its closure has been analysed and, for an activation, switched to; the
# profile roots what was activated, and the indirect root Nix registered for
# the link is dropped with it.
candidate_link_path() { # host
  local directory="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode"
  mkdir -p "$directory"
  mktemp -u "$directory/candidate-$1.XXXXXXXX"
}

# One machine, one activation or service mutation at a time. apply and
# rollback take this before they read the current generation and hold it
# past the switch, so the generation a report was computed against is the one
# still running when the switch starts; every manifold-agent start, stop,
# restart and enrollment takes it too, so a report that found the owner
# unloaded cannot be overtaken by a start, nor a transport restart by an
# activation that changes its role. The lock is an flock on a descriptor
# this shell keeps open: taken by the analyzer, it lives with the open file
# description, which the child leaves behind when it exits. /tmp because
# root's rollback and the user's apply must contend for the same file, and
# because a lock a user cannot see is not a lock.
#
# apply hands work to a child atyrode (a provisioning offer runs `runtime
# provision manifold-agent`) while it holds the lock, so the child must not
# contend with its parent. It inherits the descriptor's number, and takes it
# on proof rather than trust: the analyzer checks by fstat that the number
# names the lock file and then flocks it, which a descriptor sharing the
# parent's open file description reacquires and any other descriptor either
# takes for real or is refused on. A number that proves nothing is ignored
# and the lock is opened afresh.
readonly activation_lock_file=/tmp/atyrode-activation.lock
activation_lock_fd=""
activation_lock() {
  [[ -z "$activation_lock_fd" ]] || return 0
  { : >>"$activation_lock_file"; } 2>/dev/null || true
  local inherited="${ATYRODE_ACTIVATION_LOCK_FD:-}"
  if [[ "$inherited" =~ ^[0-9]+$ && -e "/dev/fd/$inherited" ]] &&
    "$atyrode_disruption" --hold-lock-fd "$inherited" --lock-file "$activation_lock_file" 2>/dev/null; then
    activation_lock_fd="$inherited"
  else
    exec {activation_lock_fd}<"$activation_lock_file" ||
      die "$EX_UNAVAILABLE" "cannot open the activation lock $activation_lock_file"
    "$atyrode_disruption" --hold-lock-fd "$activation_lock_fd" --lock-file "$activation_lock_file" ||
      die "$EX_UNAVAILABLE" "another activation or service mutation holds $activation_lock_file (an apply, rollback or manifold-agent operation is in progress); let it finish, or inspect it with: atyrode apply-status"
  fi
  export ATYRODE_ACTIVATION_LOCK_FD="$activation_lock_fd"
}

# The manager commands the analyzer may ask, through the seams every other
# status query uses, and -- in a test-hooks build only -- the identity the
# analyzer holds while asking: the account whose managers count as its own,
# the effective uid a check simulates (root asks every live user manager
# through --machine, anyone else only their own), and where live user
# managers are enumerated from (/run/user in production). A production build
# passes none of these and the analyzer reads them from the OS.
disruption_manager_args() { # out-array-name
  local -n out="$1"
  out=()
  local systemctl launchctl
  if systemctl="$(optional_host_command ATYRODE_SYSTEMCTL systemctl)"; then
    out+=(--systemctl "$systemctl")
  fi
  if launchctl="$(optional_host_command ATYRODE_LAUNCHCTL launchctl)"; then
    out+=(--launchctl "$launchctl")
  fi
  [[ "$test_hooks" != 1 ]] || {
    out+=(--manager-user "$(actual_user)" --manager-uid "$(effective_uid)")
    [[ -z "${_ATYRODE_TEST_RUN_USER_DIR:-}" ]] || out+=(--run-user-dir "$_ATYRODE_TEST_RUN_USER_DIR")
  }
}

# The report, as JSON on stdout. A report is produced whenever the analyzer
# ran; its status carries the verdict. Only the analyzer failing to run at all
# is an error here, and that is refused like any other unknown.
#
# The manager is always asked whether a protected unit the engine would touch
# is loaded at all, through the same seams every other status query uses. A
# preview asks unlocked and an activation asks again under the lock; the
# answer is part of the effects, so it is part of the fingerprint, and a unit
# that came back between the two makes the acknowledgement stale.
disruption_analyze() { # host activation current candidate user scope...
  local host="$1" activation="$2" current="$3" candidate="$4" user="$5"
  shift 5
  local -a args=(--host "$host" --activation "$activation" --current "$current" --candidate "$candidate" --runtime)
  [[ -z "$user" ]] || args+=(--user "$user")
  local -a manager_args
  disruption_manager_args manager_args
  args+=("${manager_args[@]+"${manager_args[@]}"}")
  local scope
  for scope in "$@"; do
    args+=(--scope "$scope")
  done
  [[ -x "$atyrode_disruption" ]] ||
    die "$EX_UNAVAILABLE" "the disruption analyzer is unavailable, so no activation can be shown safe"
  "$atyrode_disruption" "${args[@]}"
}

# The same reading, for a stop or restart asked of one unit outside any
# activation (`runtime stop|restart manifold-agent`, token rotation). The
# unit's role is read from the definition the running generation deploys and
# from the file the manager loaded, which must agree; a unit holding the
# session-owner role is refused while the manager reports it loaded, and
# only a manager proving it is not loaded turns the request into a plain
# start. There is no flag past this: a deliberately drained owner is stopped
# through the manager by the operator, after which apply migrates it.
disruption_mutation_guard() { # scope:service action live-path
  local target="$1" action="$2" live="$3" host data activation user current report
  validate_scope "$target"
  host="$(resolve_host "")"
  data="$(host_json "$host")"
  activation="$(jq -r '.activation' <<<"$data")"
  user="$(jq -r '.username' <<<"$data")"
  current="$(current_generation "$activation" "$user")" ||
    die "$EX_UNAVAILABLE" "the generation $host runs now cannot be named, so a $action of ${target#*:} cannot be shown safe"
  [[ -n "$current" ]] ||
    die "$EX_UNAVAILABLE" "$host has no activated generation, so ${target#*:} has no deployed definition to read; activate first"
  local -a args=(--host "$host" --activation "$activation" --current "$current" --user "$user" --runtime --mutate "$action" --service "$target")
  [[ -z "$live" ]] || args+=(--live "$live")
  local -a manager_args
  disruption_manager_args manager_args
  args+=("${manager_args[@]+"${manager_args[@]}"}")
  [[ -x "$atyrode_disruption" ]] ||
    die "$EX_UNAVAILABLE" "the disruption analyzer is unavailable, so no service mutation can be shown safe"
  report="$("$atyrode_disruption" "${args[@]}")" ||
    die "$EX_UNAVAILABLE" "the disruption analyzer did not produce a report, and a $action without one cannot be shown safe"
  disruption_render "$report"
  case "$(jq -r '.status' <<<"$report")" in
    safe) ;;
    blocked)
      die "$EX_UNAVAILABLE" "$action refused: ${target#*:} holds the session-owner role and is loaded, so a $action ends every session it holds; drain it and stop it through the manager deliberately, then migrate it with atyrode apply"
      ;;
    *)
      die "$EX_UNAVAILABLE" "$action refused: whether ${target#*:} may be disrupted could not be established (see the report above)"
      ;;
  esac
}

# `--scope scope:service` is checked here rather than trusted to reach the
# analyzer well-formed, because a malformed scope silently matching nothing
# would widen what an operator meant to narrow.
validate_scope() { # scope
  [[ "$1" =~ ^(system|user|launchd):[^[:space:]]+$ ]] ||
    die "$EX_USAGE" "--scope expects system|user|launchd:service (for example system:caddy.service), got: $1"
}

# What an operator reads: one line per effect, then why the verdict is what
# it is. Painted by severity so a blocked report cannot be skimmed as fine.
disruption_render() { # report
  local report="$1" status line
  status="$(jq -r '.status' <<<"$report")"
  case "$status" in
    safe) say "$(paint '1;32' 'disruption: safe') $(paint 2 "fingerprint $(jq -r '.fingerprint' <<<"$report")")" ;;
    blocked) say "$(paint '1;31' 'disruption: blocked')" ;;
    *) say "$(paint '1;33' "disruption: $status")" ;;
  esac
  say "$(paint 2 "current   $(jq -r '.currentGeneration | if . == "" then "(none: first activation)" else . end' <<<"$report")")"
  say "$(paint 2 "candidate $(jq -r '.candidateGeneration' <<<"$report")")"
  if [[ "$(jq -r '.effects | length' <<<"$report")" == 0 ]]; then
    say "  $(paint 2 'no service is started, stopped, restarted or reloaded')"
  fi
  while IFS= read -r line; do
    say "  $line"
  done < <(jq -r '
    .effects[] |
    "\(.scope)\(if .user then "@" + .user else "" end):\(.service)  \(.action)\(if .protected then "  [protected]" else "" end)  -- \(.reason)"
  ' <<<"$report")
  while IFS= read -r line; do
    say "  $(paint '1;31' 'refused:') $line"
  done < <(jq -r '.reasons[]' <<<"$report")
}

# The verdict, applied. Returns only when the switch may proceed; every other
# outcome names what stood in the way and stops the run before any mutation.
# `expected` tightens: an acknowledgement for a different report is a stale
# one, and a stale acknowledgement is worse than none because it says the
# operator looked at something other than what is about to happen.
disruption_enforce() { # report expected candidate
  local report="$1" expected="$2" candidate="$3" status fingerprint
  status="$(jq -r '.status' <<<"$report")"
  fingerprint="$(jq -r '.fingerprint' <<<"$report")"
  log_event "disruption report: $(jq -c . <<<"$report")"
  case "$status" in
    safe) ;;
    blocked)
      die "$EX_UNAVAILABLE" "activation refused: it would disrupt a protected service (see the report above); the inspected closure is $candidate and switching it is a deliberate operator maintenance -- drain its sessions first -- not an unattended apply"
      ;;
    *)
      die "$EX_UNAVAILABLE" "activation refused: the service impact of $candidate could not be established (see the report above); an unknown impact cannot be shown safe, so make the generation readable or fix what the report names, then preview again"
      ;;
  esac
  if [[ -n "$expected" && "$expected" != "$fingerprint" ]]; then
    die "$EX_DATAERR" "activation refused: --expected-disruption names report $expected but the report for this candidate is $fingerprint; the candidate, the running generation or its effects changed since that preview, so preview again and acknowledge the report you read"
  fi
}

# The candidate, and nothing else, becomes the system. nh switches an exact
# store path for NixOS and Home Manager; nh darwin does not accept one, so the
# two commands nh would run are run directly: nix-darwin's own profile set and
# its own activate, on the inspected closure. Nothing here re-evaluates a
# flake, so the generation activated is the generation analyzed.
activate_closure() { # activation candidate nh_locale nh_command
  local activation="$1" candidate="$2" nh_locale="$3" nh_command="$4"
  local -a nh_args
  case "$activation" in
    home-manager) nh_args=("$nh_command" home switch "$candidate" --backup-extension backup --diff always) ;;
    nixos-wsl | nixos) nh_args=("$nh_command" os switch "$candidate" --diff always) ;;
    nix-darwin)
      local nix_program
      nix_program="$(command -v nix)"
      [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX:-}" ]] || nix_program="$ATYRODE_NIX"
      local -a elevate=()
      [[ "$(id -u)" -eq 0 ]] || elevate=(sudo --)
      run_visible "${elevate[@]+"${elevate[@]}"}" "$nix_program" build --no-link --profile /nix/var/nix/profiles/system "$candidate" || return 1
      run_visible "${elevate[@]+"${elevate[@]}"}" "$candidate/sw/bin/darwin-rebuild" activate
      return
      ;;
  esac
  show_command env "LC_ALL=$nh_locale" "${nh_args[@]}"
  LC_ALL="$nh_locale" "${nh_args[@]}"
}
