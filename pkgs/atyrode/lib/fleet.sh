# shellcheck shell=bash
#
# Deploying a machine of this clan that the operator is not sitting at.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.
#
# `atyrode apply` converges the machine it runs on. This is the other half:
# the same convergence for a machine reached over SSH, which clan performs by
# building the closure here and activating it there. It replaced a ceremony
# that drove a second repository through `nix develop`, fetched an operator
# identity out of Bitwarden on every run, and read the target's address from
# that repository's enrollment inventory. All three are gone: the machines are
# this flake's, the operator identity is the device's own key, and the address
# is what the machine itself declares to clan.

fleet_ssh_visible() { tool_exec visible ATYRODE_SSH ssh "$@"; }
fleet_nix() { tool_exec quiet ATYRODE_NIX nix "$@"; }
fleet_nix_visible() { tool_exec visible ATYRODE_NIX nix "$@"; }

# The repository clan builds from. Conventionally the operator's checkout,
# because a deployment must be reproducible from a revision someone can name
# and the published flake is that revision only by accident.
fleet_repository() { # repo
  local repo="$1"
  [[ -n "$repo" ]] || repo="$HOME/nix-dotfiles"
  [[ "$repo" == /* ]] || die "$EX_USAGE" "the repository path must be absolute: $repo"
  [[ -e "$repo/flake.nix" ]] ||
    die "$EX_NOINPUT" "not a checkout of this repository: $repo (name one with --repo)"
  printf '%s' "$repo"
}

# Which machines this command can reach. A portable Home Manager profile has no
# system closure to activate and no clan record; the local machine has
# `atyrode apply`, which does the same work without a network in the way.
fleet_target_host() { # requested
  local requested="$1" host data activation
  host="$(resolve_host "$requested")"
  data="$(host_json "$host")"
  activation="$(jq -r '.activation' <<<"$data")"
  case "$activation" in
    nixos | nix-darwin | nixos-wsl) ;;
    *) die "$EX_USAGE" "$host activates with $activation, which clan does not deploy; it converges with atyrode apply on the machine itself" ;;
  esac
  printf '%s' "$host"
}

cmd_fleet() {
  local action="${1:-}"
  case "$action" in
    plan | apply) shift ;;
    *) die "$EX_USAGE" "fleet expects plan or apply" ;;
  esac

  local requested="" repo="" json=0 assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        shift
        repo="${1:-}"
        [[ -n "$repo" ]] || die "$EX_USAGE" "--repo expects a path"
        ;;
      --json) json=1 ;;
      -y | --yes) assume_yes=1 ;;
      --*) die "$EX_USAGE" "unknown fleet $action option: $1" ;;
      *)
        [[ -z "$requested" ]] || die "$EX_USAGE" "fleet $action accepts at most one host"
        requested="$1"
        ;;
    esac
    shift || true
  done
  [[ "$action" == apply || "$assume_yes" == 0 ]] ||
    die "$EX_USAGE" "--yes is valid only for fleet apply"
  [[ -n "$requested" ]] ||
    die "$EX_USAGE" "fleet $action names the machine to deploy; this machine converges with atyrode apply"

  local host clan target
  host="$(fleet_target_host "$requested")"
  [[ "$host" != "$(resolve_host "")" ]] ||
    die "$EX_USAGE" "$host is this machine; converge it with atyrode apply"
  repo="$(fleet_repository "$repo")"
  clan="$(clan_program)"

  # Where clan will reach the machine is the machine's own declaration, so a
  # deployment cannot be aimed somewhere the reviewed configuration does not
  # name. A darwin machine keeps the same attribute under its own class.
  local class
  for class in nixosConfigurations darwinConfigurations; do
    target="$(fleet_nix eval --raw \
      "$repo#$class.$host.config.clan.core.networking.targetHost" 2>/dev/null)" && break
    target=""
  done
  [[ -n "$target" ]] ||
    die "$EX_DATAERR" "$host declares no clan.core.networking.targetHost, so there is nowhere to deploy it"

  if [[ "$action" == plan ]]; then
    plan_steps "Check $host's vars are generated and readable" \
      "Reach $host over SSH" \
      "Evaluate what would be built"
  else
    plan_steps "Check $host's vars are generated and readable" \
      "Reach $host over SSH" \
      "Build here and activate on $host" \
      "Verify $host reports itself converged"
  fi

  step_begin "Check $host's vars are generated and readable"
  step_why "an activation that cannot decrypt this machine's secrets half-converges it"
  if ! run_visible "$clan" vars check "$host" --flake "$repo"; then
    step_fail "clan reports $host's vars incomplete"
    die "$EX_SOFTWARE" "generate them on an operator device with: clan vars generate $host"
  fi
  step_ok

  step_begin "Reach $host over SSH"
  step_why "the deployment fails halfway if the machine is unreachable or its host key changed"
  if ! fleet_ssh_visible -o BatchMode=yes -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 "$target" true; then
    step_fail "$target did not answer a strict-host-key SSH check"
    die "$EX_UNAVAILABLE" "make $target reachable, then run this again"
  fi
  step_ok "$target answered"

  if [[ "$action" == plan ]]; then
    local drv_path
    step_begin "Evaluate what would be built"
    step_why "a plan names the derivation an apply would realise"
    drv_path="$(fleet_nix_visible eval --raw \
      "$repo#nixosConfigurations.$host.config.system.build.toplevel.drvPath")" || {
      step_fail "$host does not evaluate"
      die "$EX_SOFTWARE" "fix the configuration before deploying it"
    }
    step_ok
    if [[ "$json" == 1 ]]; then
      jq -nc --arg host "$host" --arg repository "$repo" --arg targetHost "$target" \
        --arg drvPath "$drv_path" \
        '{ok:true,action:"plan",host:$host,repository:$repository,targetHost:$targetHost,
          drvPath:$drvPath,hostKeyCheck:"strict",buildHost:"localhost",
          mutationBoundary:"read-only until fleet apply"}'
    else
      printf '\nNo changes were made. Run fleet apply to deploy this.\n' >&2
    fi
    return 0
  fi

  guard_production_mutation "fleet apply"
  if [[ "$assume_yes" == 0 ]]; then
    confirm "build $host here and activate it on $target now?" || return 0
  fi

  step_begin "Build here and activate on $host"
  step_why "clan builds the closure on this machine and activates it there, so the target needs no toolchain"
  if ! run_visible "$clan" machines update "$host" --flake "$repo" \
    --target-host "$target" --build-host localhost --upload-inputs \
    --host-key-check strict; then
    step_fail "the deployment did not complete"
    die "$EX_SOFTWARE" "clear what clan reported above, then: atyrode fleet apply $host"
  fi
  step_ok

  step_begin "Verify $host reports itself converged"
  step_why "a deployment that activated the wrong generation still exits zero"
  if ! fleet_ssh_visible -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" \
    atyrode doctor host --json |
    jq -e --arg host "$host" '.ok == true and .host == $host' >/dev/null; then
    step_fail "$host did not verify its own identity after activation"
    die "$EX_SOFTWARE" "the closure activated but $host does not report itself as $host"
  fi
  step_ok

  if [[ "$json" == 1 ]]; then
    jq -nc --arg host "$host" --arg targetHost "$target" \
      '{ok:true,action:"apply",host:$host,targetHost:$targetHost,verified:true}'
  fi
}
