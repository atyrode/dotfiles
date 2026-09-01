# shellcheck shell=bash
#
# Operator infrastructure setup and planning.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# Under test each program below is a stub, so every call resolves its override
# here instead of naming the binary inline.
#
# Visibility belongs to the call site rather than the program: `git rev-parse`
# only looks while `git clone` acts, and announcing from inside one wrapper
# would bury the handful of commands that change something under the dozen that
# ask a question. The `_visible` suffix is a warning as much as a convenience --
# what it is handed reaches the terminal and the run log, so it may carry the
# path to a secret but never a secret itself.
infra_exec() { # quiet|visible override_variable program argv...
  local visibility="$1" override="$2" program="$3"
  shift 3
  [[ "$test_hooks" != 1 || -z "${!override:-}" ]] || program="${!override}"
  if [[ "$visibility" == visible ]]; then
    run_visible "$program" "$@"
  else
    "$program" "$@"
  fi
}

infra_age_keygen() { infra_exec quiet ATYRODE_AGE_KEYGEN age-keygen "$@"; }
infra_nix_visible() { infra_exec visible ATYRODE_NIX nix "$@"; }
infra_ssh_visible() { infra_exec visible ATYRODE_SSH ssh "$@"; }
infra_git() { infra_exec quiet ATYRODE_GIT git "$@"; }
infra_git_visible() { infra_exec visible ATYRODE_GIT git "$@"; }

infra_synchronize_apply_checkout() {
  local repo="$1" branch head remote_head merge_base updated_head
  [[ -z "$(infra_git -C "$repo" status --porcelain)" ]] ||
    die "$EX_DATAERR" "infra checkout is dirty; review and commit it before apply"
  branch="$(infra_git -C "$repo" symbolic-ref --quiet --short HEAD)" ||
    die "$EX_DATAERR" "infra apply requires the main branch, not a detached checkout"
  [[ "$branch" == main ]] ||
    die "$EX_DATAERR" "infra apply requires the main branch; current branch is $branch"
  # This fetch and the fast-forward below choose the revision the deployment
  # will build, and either can stall on a network that is gone, so both are
  # named rather than left as an unexplained pause before a new revision.
  infra_git_visible -C "$repo" fetch --quiet origin \
    refs/heads/main:refs/remotes/origin/main ||
    die "$EX_UNAVAILABLE" "could not refresh origin/main before infra apply"
  head="$(infra_git -C "$repo" rev-parse HEAD)" ||
    die "$EX_DATAERR" "could not resolve the infra checkout revision"
  remote_head="$(infra_git -C "$repo" rev-parse refs/remotes/origin/main)" ||
    die "$EX_DATAERR" "could not resolve the fetched origin/main revision"
  infra_sync_old="$head"
  infra_sync_new="$remote_head"
  infra_sync_commits=""
  [[ "$head" != "$remote_head" ]] || return 0
  merge_base="$(infra_git -C "$repo" merge-base "$head" "$remote_head")" ||
    die "$EX_DATAERR" "could not compare the infra checkout with origin/main"
  [[ "$merge_base" == "$head" ]] ||
    die "$EX_DATAERR" "infra checkout has local commits or diverged from origin/main; reconcile $repo before apply"
  infra_sync_commits="$(infra_git -C "$repo" log --oneline --no-decorate "$head..$remote_head")" ||
    die "$EX_DATAERR" "could not summarize incoming infra commits"
  infra_git_visible -C "$repo" merge --ff-only "$remote_head" >/dev/null ||
    die "$EX_SOFTWARE" "could not fast-forward the infra checkout to origin/main"
  updated_head="$(infra_git -C "$repo" rev-parse HEAD)" ||
    die "$EX_DATAERR" "could not verify the updated infra checkout revision"
  [[ "$updated_head" == "$remote_head" ]] ||
    die "$EX_SOFTWARE" "infra checkout did not reach the fetched origin/main revision"
}

infra_print_apply_source() {
  local machine="$1" target="$2" line
  printf 'atyrode: deployment source for %s at %s: %s -> %s\n' \
    "$machine" "$target" "${infra_sync_old:0:12}" "${infra_sync_new:0:12}" >&2
  if [[ -n "$infra_sync_commits" ]]; then
    printf 'atyrode: incoming infra commits:\n' >&2
    while IFS= read -r line; do
      printf '  %s\n' "$line" >&2
    done <<<"$infra_sync_commits"
  else
    printf 'atyrode: infra checkout already matches origin/main\n' >&2
  fi
}

infra_ensure_recipient() {
  local repo="$1" machine="$2" recipient="$3"
  local clan_file="$repo/clan.nix"
  if grep -Fq "\"$recipient\"" "$clan_file"; then
    printf 'false\n'
    return
  fi

  local marker='  vars.settings.secretStore = "age";'
  [[ "$(grep -Fxc "$marker" "$clan_file")" == 1 ]] ||
    die "$EX_DATAERR" "cannot safely add the operator recipient: clan.nix secret-store marker changed"
  local rendered="$repo/.clan.nix.atyrode.$$"
  awk -v marker="$marker" -v machine="$machine" -v recipient="$recipient" '
    {
      print
      if ($0 == marker) {
        print ""
        print "  # Portable operator identity managed by `atyrode infra`."
        print "  # The private half remains in Bitwarden; only this public recipient is Git state."
        print "  vars.settings.recipients.hosts." machine " = ["
        print "    \"" recipient "\""
        print "  ];"
      }
    }
  ' "$clan_file" >"$rendered" || {
    rm -f -- "$rendered"
    die "$EX_SOFTWARE" "could not render the Clan recipient update"
  }
  mv -- "$rendered" "$clan_file" ||
    die "$EX_SOFTWARE" "could not install the Clan recipient update"
  # `mv` is bookkeeping, but the file it rewrites is Git state, so the path is
  # named -- on stderr, because this function's stdout is the caller's answer.
  printf 'atyrode: added the operator recipient for %s to %s\n' "$machine" "$clan_file" >&2
  printf 'true\n'
}

cmd_infra() {
  local action="${1:-}"
  case "$action" in
    setup | plan | apply) shift ;;
    *) die "$EX_USAGE" "infra expects setup, plan, or apply" ;;
  esac

  local repo="" json=0 assume_yes=0
  local infra_sync_old="" infra_sync_new="" infra_sync_commits=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        shift
        repo="${1:-}"
        [[ -n "$repo" ]] || die "$EX_USAGE" "--repo expects a path"
        ;;
      --json) json=1 ;;
      -y | --yes) assume_yes=1 ;;
      *) die "$EX_USAGE" "unknown infra option: $1" ;;
    esac
    shift || true
  done
  [[ "$action" == apply || "$assume_yes" == 0 ]] ||
    die "$EX_USAGE" "--yes is valid only for infra apply"

  local repository checkout machine target item_id item_name expected_recipient
  repository="$(jq -er '.repository' "$operator_infra")"
  checkout="$(jq -er '.checkoutDirectory' "$operator_infra")"
  machine="$(jq -er '.machine' "$operator_infra")"
  item_id="$(jq -er '.vaultItemId' "$operator_infra")"
  item_name="$(jq -er '.vaultItemName' "$operator_infra")"
  expected_recipient="$(jq -er '.publicRecipient' "$operator_infra")"
  repo="${repo:-$HOME/$checkout}"
  [[ "$repo" == /* ]] || die "$EX_USAGE" "infra repository path must be absolute: $repo"

  if [[ ! -d "$repo/.git" && ! -f "$repo/.git" ]]; then
    [[ "$action" == setup ]] ||
      die "$EX_NOINPUT" "infra checkout is missing at $repo; run 'atyrode infra setup'"
    mkdir -p "$(dirname "$repo")"
    infra_git_visible clone "$repository" "$repo" ||
      die "$EX_UNAVAILABLE" "could not clone $repository"
  fi
  [[ -f "$repo/flake.nix" && -f "$repo/clan.nix" ]] ||
    die "$EX_DATAERR" "not a tyrode-infra checkout: $repo"
  [[ "$action" != apply ]] || infra_synchronize_apply_checkout "$repo"
  local enrollment_inventory="$repo/inventory/vps-enrollment.json"
  local network_intent="$repo/machines/$machine/network-intent.json"
  [[ -f "$enrollment_inventory" && -f "$network_intent" ]] ||
    die "$EX_DATAERR" "tyrode-infra lacks deployment identity for $machine"
  local target_user target_address
  target_user="$(
    jq -er --arg machine "$machine" \
      '.machines[$machine] as $host
       | .roles[$host.role].profile as $profile
       | .profiles[$profile].username' "$enrollment_inventory"
  )" || die "$EX_DATAERR" "cannot resolve the deployment user for $machine"
  target_address="$(
    jq -er \
      '[.uplinks[].addresses[] | select(.family == "ipv4") | .value]
       | select(length == 1) | .[0]' "$network_intent"
  )" || die "$EX_DATAERR" "cannot resolve the unique IPv4 deployment address for $machine"
  target="$target_user@$target_address"
  [[ "$action" != apply ]] || infra_print_apply_source "$machine" "$target"

  vault_open_session "$([[ "$action" == setup ]] && printf 1 || printf 0)"

  local tmp key actual_recipient result=0
  tmp="$(vault_secure_temp_dir atyrode-infra)"
  key="$tmp/operator.agekey"
  infra_cleanup() {
    rm -rf -- "${tmp:-}"
    unset AGE_KEYFILE
    vault_close_session
  }
  trap infra_cleanup EXIT HUP INT TERM

  bw_cli get item "$item_id" |
    jq -er --arg name "$item_name" \
      'select(.name == $name) | .notes | select(type == "string" and (split("\n") | any(startswith("AGE-SECRET-KEY-"))))' >"$key" ||
    die "$EX_DATAERR" "Bitwarden does not contain the reviewed Tyrode operator identity"
  actual_recipient="$(infra_age_keygen -y "$key")" ||
    die "$EX_DATAERR" "Bitwarden Tyrode operator identity is invalid"
  [[ "$actual_recipient" == "$expected_recipient" ]] ||
    die "$EX_DATAERR" "Bitwarden identity does not match the reviewed public recipient"
  export AGE_KEYFILE="$key"

  if [[ "$action" == setup ]]; then
    guard_production_mutation "infra setup"
    local source_changed
    source_changed="$(infra_ensure_recipient "$repo" "$machine" "$expected_recipient")"
    infra_nix_visible develop "$repo" --command nixfmt "$repo/clan.nix" ||
      die "$EX_SOFTWARE" "could not format the Clan recipient update"
    infra_nix_visible develop "$repo" --command env "AGE_KEYFILE=$key" \
      clan vars fix "$machine" --flake "$repo" ||
      die "$EX_SOFTWARE" "Clan recipient enrollment failed"
    infra_nix_visible develop "$repo" --command env "AGE_KEYFILE=$key" \
      clan vars check "$machine" --flake "$repo" ||
      die "$EX_SOFTWARE" "Clan Vars check failed after enrollment"
    if [[ "$json" == 1 ]]; then
      jq -nc --arg machine "$machine" --arg repository "$repo" \
        --argjson sourceChanged "$source_changed" \
        '{ok:true,action:"setup",machine:$machine,repository:$repository,
          sourceChanged:$sourceChanged,privateMaterialPrinted:false}'
    else
      printf 'atyrode: Clan operator enrollment is valid for %s\n' "$machine"
      if [[ -n "$(infra_git -C "$repo" status --porcelain)" ]]; then
        printf 'atyrode: review and commit the encrypted Clan changes in %s before apply\n' "$repo"
      fi
    fi
  else
    [[ "$action" != plan || -z "$(infra_git -C "$repo" status --porcelain)" ]] ||
      die "$EX_DATAERR" "infra checkout is dirty; review and commit it before plan"
    infra_nix_visible develop "$repo" --command env "AGE_KEYFILE=$key" \
      clan vars check "$machine" --flake "$repo" ||
      die "$EX_SOFTWARE" "Clan Vars check failed"
    infra_ssh_visible -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \
      "$target" true ||
      die "$EX_UNAVAILABLE" "strict SSH preflight failed for $target"
    local drv_path
    drv_path="$(infra_nix_visible eval --raw \
      "$repo#nixosConfigurations.$machine.config.system.build.toplevel.drvPath")" ||
      die "$EX_SOFTWARE" "NixOS target evaluation failed"

    if [[ "$action" == plan ]]; then
      if [[ "$json" == 1 ]]; then
        jq -nc --arg machine "$machine" --arg repository "$repo" \
          --arg targetHost "$target" --arg drvPath "$drv_path" \
          '{ok:true,action:"plan",machine:$machine,repository:$repository,
            targetHost:$targetHost,drvPath:$drvPath,hostKeyCheck:"strict",
            buildHost:"localhost",privateMaterialPrinted:false}'
      else
        printf 'machine: %s\nrepository: %s\ntarget: %s\nbuild host: %s\nhost key check: strict\nderivation: %s\n' \
          "$machine" "$repo" "$target" "localhost" "$drv_path"
        printf 'atyrode: plan passed; no activation was performed\n'
      fi
    else
      guard_production_mutation "infra apply"
      if [[ "$assume_yes" == 0 ]]; then
        confirm "deploy $machine to $target from ${infra_sync_new:0:12} now?" || {
          infra_cleanup
          trap - EXIT HUP INT TERM
          return 0
        }
      fi
      # Activating a production host over the network is the most consequential
      # thing this CLI does, and a confirmation prompt says what is about to
      # happen while only the argv says how to retry it. AGE_KEYFILE carries the
      # path to the operator identity rather than the identity, so nothing
      # secret reaches the terminal or the run log.
      infra_nix_visible develop "$repo" --command env "AGE_KEYFILE=$key" \
        clan machines update "$machine" --flake "$repo" \
        --target-host "$target" --build-host localhost --upload-inputs \
        --host-key-check strict ||
        die "$EX_SOFTWARE" "Clan deployment failed"
      infra_ssh_visible -o BatchMode=yes -o StrictHostKeyChecking=yes "$target" \
        atyrode doctor host --json |
        jq -e --arg machine "$machine" \
          '.ok == true and .host == $machine and .registered.activation == "nixos"' >/dev/null ||
        die "$EX_SOFTWARE" "deployment completed, but host identity verification failed"
      if [[ "$json" == 1 ]]; then
        jq -nc --arg machine "$machine" --arg targetHost "$target" \
          '{ok:true,action:"apply",machine:$machine,targetHost:$targetHost,verified:true,
            privateMaterialPrinted:false}'
      else
        printf 'atyrode: %s deployed and verified through %s\n' "$machine" "$target"
      fi
    fi
  fi

  infra_cleanup
  trap - EXIT HUP INT TERM
  return "$result"
}
