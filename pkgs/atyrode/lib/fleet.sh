# shellcheck shell=bash
#
# Deploying a machine of this clan that the operator is not sitting at.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.
#
# `atyrode apply` converges the machine it runs on. This is the other half:
# the same convergence for a machine reached over SSH. The closure is built
# here and copied there, exactly as clan's `machines update` did, and clan
# still places the machine's secrets; what changed after 2026-09-05 is who
# activates. clan's activation ran switch-to-configuration on whatever it had
# just copied, with no reading of what that switch did to the services on the
# other end. Now the copied closure is handed to the target's own `atyrode
# apply --candidate`, which reads it against the generation running there and
# refuses on the same terms as a local apply: the fleet has no weaker path.
# The report crosses back as the same JSON the cockpit reads, and the
# activation that follows is bound to its fingerprint.
#
# This replaced a ceremony that drove a second repository through `nix
# develop`, fetched an operator identity out of Bitwarden on every run, and
# read the target's address from that repository's enrollment inventory. All
# three are gone: the machines are this flake's, the operator identity is the
# device's own key, and the address is what the machine itself declares to
# clan.

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
# `atyrode apply`, which does the same work without a network in the way. A
# nix-darwin machine cannot be built from a Linux operator device, and clan's
# own darwin path activates on the target without the guard, so it converges
# where it sits.
fleet_target_host() { # requested
  local requested="$1" host data activation
  host="$(resolve_host "$requested")"
  data="$(host_json "$host")"
  activation="$(jq -r '.activation' <<<"$data")"
  case "$activation" in
    nixos | nixos-wsl) ;;
    nix-darwin) die "$EX_USAGE" "$host is a nix-darwin machine; its closure builds only on macOS and clan's darwin deployment activates without reading service impact, so it converges with atyrode apply on the machine itself" ;;
    *) die "$EX_USAGE" "$host activates with $activation, which the fleet does not deploy; it converges with atyrode apply on the machine itself" ;;
  esac
  printf '%s' "$host"
}

# The CLI on the target that owns the guarded activation: the one inside the
# closure being deployed, because it knows the registry and the policy that
# closure was reviewed with. It is reached through the per-user profile the
# NixOS generation carries; only if that closure has no CLI does the target's
# installed one answer instead.
fleet_remote_cli() { # target closure user
  local candidate="$2/etc/profiles/per-user/$3/bin/atyrode"
  if fleet_ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$1" test -x "$(printf '%q' "$candidate")"; then
    printf '%s' "$candidate"
  else
    printf 'atyrode'
  fi
}

fleet_ssh() { tool_exec quiet ATYRODE_SSH ssh "$@"; }

cmd_fleet() {
  local action="${1:-}"
  case "$action" in
    plan | apply) shift ;;
    *) die "$EX_USAGE" "fleet expects plan or apply" ;;
  esac

  local requested="" repo="" json=0 assume_yes=0
  local -a scopes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        shift
        repo="${1:-}"
        [[ -n "$repo" ]] || die "$EX_USAGE" "--repo expects a path"
        ;;
      --scope)
        shift
        [[ -n "${1:-}" ]] || die "$EX_USAGE" "--scope requires scope:service"
        validate_scope "$1"
        scopes+=("$1")
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
  [[ "$action" == apply || ("$assume_yes" == 0 && "${#scopes[@]}" == 0) ]] ||
    die "$EX_USAGE" "--yes and --scope are valid only for fleet apply"
  [[ -n "$requested" ]] ||
    die "$EX_USAGE" "fleet $action names the machine to deploy; this machine converges with atyrode apply"

  local host clan target user
  host="$(fleet_target_host "$requested")"
  [[ "$host" != "$(resolve_host "")" ]] ||
    die "$EX_USAGE" "$host is this machine; converge it with atyrode apply"
  user="$(jq -r '.username' <<<"$(host_json "$host")")"
  repo="$(fleet_repository "$repo")"
  clan="$(clan_program)"

  # Where clan will reach the machine is the machine's own declaration, so a
  # deployment cannot be aimed somewhere the reviewed configuration does not
  # name.
  target="$(fleet_nix eval --raw \
    "$repo#nixosConfigurations.$host.config.clan.core.networking.targetHost" 2>/dev/null)" || target=""
  [[ -n "$target" ]] ||
    die "$EX_DATAERR" "$host declares no clan.core.networking.targetHost, so there is nowhere to deploy it"

  if [[ "$action" == plan ]]; then
    plan_steps "Check $host's vars are generated and readable" \
      "Reach $host over SSH" \
      "Evaluate what would be built"
  else
    plan_steps "Check $host's vars are generated and readable" \
      "Reach $host over SSH" \
      "Build $host's closure here" \
      "Copy the closure to $host" \
      "Preview what activating it does to $host's services" \
      "Place $host's secrets through clan" \
      "Activate the inspected closure on $host" \
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

  local closure
  step_begin "Build $host's closure here"
  step_why "the target needs no toolchain, and what is analysed there is exactly what was built here"
  closure="$(fleet_nix_visible build --no-link --print-out-paths \
    "$repo#nixosConfigurations.$host.config.system.build.toplevel")" || closure=""
  [[ "$closure" == /nix/store/* ]] || {
    step_fail "$host did not build"
    die "$EX_SOFTWARE" "fix the configuration before deploying it"
  }
  step_ok "$closure"

  # Copying registers the closure's paths on the target without activating
  # anything; a copied closure nobody switches to is garbage the next clean
  # collects. Signatures are not checked because the operator account is a
  # trusted user of the target's daemon (fleet/hosts.nix), which is what lets
  # a closure built here be accepted there at all.
  step_begin "Copy the closure to $host"
  step_why "the target activates a closure it already holds, never one it has to fetch mid-switch"
  if ! NIX_SSHOPTS='-o BatchMode=yes -o StrictHostKeyChecking=yes' \
    fleet_nix_visible copy --to "ssh-ng://$target" --no-check-sigs "$closure"; then
    step_fail "the closure did not reach $host"
    die "$EX_UNAVAILABLE" "clear what nix reported above, then: atyrode fleet apply $host"
  fi
  step_ok

  local remote_cli preview report fingerprint
  local -a scope_args=()
  local scope
  for scope in "${scopes[@]+"${scopes[@]}"}"; do
    scope_args+=(--scope "$scope")
  done
  step_begin "Preview what activating it does to $host's services"
  step_why "the report is computed on $host against the generation running there, before anything is queued for a stop"
  remote_cli="$(fleet_remote_cli "$target" "$closure" "$user")"
  preview="$(fleet_ssh_visible -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" -- \
    "$(render_argv "$remote_cli" apply "$host" --candidate "$closure" --preview-json "${scope_args[@]+"${scope_args[@]}"}")")" || {
    step_fail "$host produced no preview"
    die "$EX_UNAVAILABLE" "the target refused or failed to preview the closure; read its output above"
  }
  report="$(jq -ce '.disruption // empty' <<<"$preview")" || {
    step_fail "$host's preview carries no disruption report"
    die "$EX_UNAVAILABLE" "the atyrode on $host predates the disruption guard, so its activation cannot be shown safe; deploy a closure whose CLI carries the guard first, or converge $host on the machine itself"
  }
  disruption_render "$report"
  fingerprint="$(jq -r '.fingerprint' <<<"$report")"
  case "$(jq -r '.status' <<<"$report")" in
    safe) step_ok ;;
    *)
      step_fail "$host refuses this activation by default"
      die "$EX_UNAVAILABLE" "activating $closure on $host would disrupt what the report names; that is a deliberate operator maintenance on the machine itself, not a fleet apply"
      ;;
  esac
  if [[ "$assume_yes" == 0 ]]; then
    confirm "activate this closure on $target now?" || return 0
  fi

  step_begin "Place $host's secrets through clan"
  step_why "sops-nix decrypts $host's vars at activation with the key clan places"
  if ! run_visible "$clan" vars upload "$host" --flake "$repo"; then
    step_fail "clan could not place $host's secrets"
    die "$EX_SOFTWARE" "clear what clan reported above, then: atyrode fleet apply $host"
  fi
  step_ok

  # The fingerprint the operator just read is what the target is told to
  # expect: if its running generation moved, or the closure's effects are not
  # what was previewed, the target refuses rather than trusting this side.
  step_begin "Activate the inspected closure on $host"
  step_why "the target reads the closure again under its activation lock and switches only the report it was shown"
  if ! fleet_ssh_visible -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" -- \
    "$(render_argv "$remote_cli" apply "$host" --candidate "$closure" --expected-disruption "$fingerprint" "${scope_args[@]+"${scope_args[@]}"}")"; then
    step_fail "the activation did not complete"
    die "$EX_SOFTWARE" "clear what $host reported above, then: atyrode fleet apply $host"
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
    jq -nc --arg host "$host" --arg targetHost "$target" --arg closure "$closure" \
      --argjson disruption "$report" \
      '{ok:true,action:"apply",host:$host,targetHost:$targetHost,closure:$closure,
        disruption:$disruption,verified:true}'
  fi
}
