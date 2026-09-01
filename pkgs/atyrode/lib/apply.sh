# shellcheck shell=bash
#
# Activation, and the declared state apply converges around it.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

create_runtime_adapter() {
  local profile="$1" data="$2" source="$3" git_auth_mode="$4" directory source_literal
  directory="$(mktemp -d)"
  jq -n --arg profileName "$profile" \
    --arg username "$(jq -r '.username' <<<"$data")" \
    --arg homeDirectory "$(jq -r '.homeDirectory' <<<"$data")" \
    --arg gitAuthMode "$git_auth_mode" \
    '{profileName:$profileName,username:$username,homeDirectory:$homeDirectory,gitAuthMode:$gitAuthMode}' \
    >"$directory/identity.json"
  source_literal="$(jq -Rn --arg source "$source" '$source')"
  cat >"$directory/flake.nix" <<EOF
{
  inputs.dotfiles.url = $source_literal;
  outputs = { self, dotfiles }: let
    identity = builtins.fromJSON (builtins.readFile ./identity.json);
  in {
    homeConfigurations.\${identity.profileName} =
      dotfiles.lib.mkPortableHomeConfiguration identity;
  };
}
EOF
  printf '%s\n' "$directory"
}
apply_config() {
  local requested="" repo="" ref="" git_auth_mode="${ATYRODE_GIT_AUTH_MODE:-}" plan=0 dry=0 json=0 preview_json=0 restart=0
  # Activation can succeed while a state apply owns is left unconverged. That
  # is not a clean apply, so it is carried to the exit code rather than being
  # printed and forgotten.
  local apply_status=0
  local -a original_args=("$@")
  if [[ $# -gt 0 && "$1" != --* ]]; then
    requested="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || die "$EX_USAGE" "--repo requires a path"
        repo="$2"
        shift 2
        ;;
      --ref)
        [[ $# -ge 2 ]] || die "$EX_USAGE" "--ref requires a branch, tag, or full commit"
        ref="$2"
        shift 2
        ;;
      --git-auth-mode)
        [[ $# -ge 2 ]] || die "$EX_USAGE" "--git-auth-mode requires ssh or https-gh"
        git_auth_mode="$2"
        shift 2
        ;;
      --plan)
        plan=1
        shift
        ;;
      --dry-run)
        dry=1
        shift
        ;;
      --preview-json)
        preview_json=1
        dry=1
        shift
        ;;
      --json)
        json=1
        shift
        ;;
      --restart-shell)
        restart=1
        shift
        ;;
      -h | --help)
        usage
        return
        ;;
      *) die "$EX_USAGE" "unknown apply option: $1" ;;
    esac
  done
  [[ -z "$repo" || -z "$ref" ]] || die "$EX_USAGE" "--ref selects a published revision and cannot be combined with --repo"
  [[ "$preview_json" == 0 || "$plan" == 0 ]] || die "$EX_USAGE" "--preview-json cannot be combined with --plan"
  [[ "$preview_json" == 0 || "$json" == 0 ]] || die "$EX_USAGE" "--preview-json already selects structured JSON output"
  if [[ "$apply_job_worker" == 0 && "$plan" == 0 && "$dry" == 0 ]] &&
    apply_supervision_available; then
    submit_apply_job "${original_args[@]}"
    return $?
  fi

  local host data expected_system expected_user expected_home expected_hostname platform activation identity_mode source repository flake_source revision resolved_revision dirty backend installable
  local windows_preflight='null' mutation_boundary="activation only after preflight"
  local git_command=git
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_GIT:-}" ]]; then
    git_command="$ATYRODE_GIT"
  fi
  host="$(resolve_host "$requested")"
  data="$(host_json "$host")"
  expected_system="$(jq -r '.system' <<<"$data")"
  expected_user="$(jq -r '.username' <<<"$data")"
  expected_home="$(jq -r '.homeDirectory' <<<"$data")"
  expected_hostname="$(jq -r '.hostname // empty' <<<"$data")"
  platform="$(jq -r '.platform' <<<"$data")"
  activation="$(jq -r '.activation' <<<"$data")"
  identity_mode="$(jq -r '.identityMode // "fixed"' <<<"$data")"
  if [[ "$identity_mode" == runtime ]]; then
    if [[ -z "$git_auth_mode" ]]; then
      local persisted_git_auth_mode="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/git-auth-mode"
      [[ ! -L "$persisted_git_auth_mode" ]] ||
        die "$EX_DATAERR" "persisted Git auth mode must not be a symlink"
      if [[ -f "$persisted_git_auth_mode" ]]; then
        git_auth_mode="$(cat "$persisted_git_auth_mode")"
      else
        git_auth_mode=ssh
      fi
    fi
    case "$git_auth_mode" in
      ssh | https-gh) ;;
      *) die "$EX_USAGE" "Git auth mode must be ssh or https-gh" ;;
    esac
  else
    git_auth_mode=ssh
  fi
  [[ "$(actual_system)" == "$expected_system" ]] || die "$EX_DATAERR" "host $host requires $expected_system, found $(actual_system)"
  [[ "$(actual_user)" == "$expected_user" ]] || die "$EX_DATAERR" "host $host requires user $expected_user, found $(actual_user)"
  [[ -z "$expected_hostname" || "$(actual_hostname)" == "$expected_hostname" ]] || die "$EX_DATAERR" "host $host requires hostname $expected_hostname, found $(actual_hostname)"
  command -v nh >/dev/null || die "$EX_UNAVAILABLE" "nh is unavailable"
  command -v "$git_command" >/dev/null || die "$EX_UNAVAILABLE" "git is unavailable"

  if [[ -n "$repo" ]]; then
    source="local"
    [[ "$repo" == /* ]] || die "$EX_USAGE" "repository path must be absolute: $repo"
    [[ -f "$repo/flake.nix" ]] || die "$EX_NOINPUT" "not a flake checkout: $repo"
    "$git_command" -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$EX_DATAERR" "repository is not a Git checkout: $repo"
    revision="$("$git_command" -C "$repo" rev-parse --short=12 HEAD)"
    resolved_revision="$("$git_command" -C "$repo" rev-parse HEAD)"
    dirty=false
    "$git_command" -C "$repo" diff --quiet --ignore-submodules HEAD -- || dirty=true
    repository="$repo"
    flake_source="$repo"
    installable="$repo#$host"
  else
    source="remote"
    ref="${ref:-main}"
    # Resolving the ref to an exact commit keeps the activation deterministic
    # and bypasses the flake tarball cache, which can serve a branch name
    # stale for up to an hour.
    local rev=""
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      rev="$ref"
    else
      rev="$("$git_command" ls-remote "$flake_remote_url" "refs/heads/$ref" "refs/tags/$ref" | head -n 1 | cut -f 1)" || true
      [[ -n "$rev" ]] || die "$EX_UNAVAILABLE" "cannot resolve $ref on $flake_remote_url; check the ref name and network"
    fi
    revision="${rev:0:12}"
    resolved_revision="$rev"
    dirty=false
    repository="$flake_ref"
    flake_source="$flake_ref/$rev"
    installable="$flake_ref/$rev#$host"
  fi
  case "$activation" in
    home-manager) backend="nh-home" ;;
    nix-darwin) backend="nh-darwin" ;;
    nixos-wsl)
      backend="nh-os"
      mutation_boundary="NixOS activation followed by non-transactional native Windows reconciliation"
      windows_preflight="$(windows_plan "$host")"
      ;;
    *) die "$EX_SOFTWARE" "host $host has unsupported activation owner $activation" ;;
  esac

  local output
  output="$(jq -nc --arg host "$host" --arg repository "$repository" --arg system "$expected_system" \
    --arg user "$expected_user" --arg homeDirectory "$expected_home" \
    --arg identityMode "$identity_mode" --arg gitAuthMode "$git_auth_mode" \
    --arg activation "$activation" --arg backend "$backend" \
    --arg revision "$revision" --arg resolvedRevision "$resolved_revision" --arg source "$source" \
    --arg installable "$installable" --arg mutationBoundary "$mutation_boundary" \
    --argjson dirty "$dirty" --argjson capabilities "$(jq -c '.capabilities' <<<"$data")" \
    --argjson windowsPlan "$windows_preflight" \
    '{host:$host,installable:$installable,source:$source,system:$system,user:$user,
      homeDirectory:$homeDirectory,identityMode:$identityMode,gitAuthMode:$gitAuthMode,
      capabilities:$capabilities,activation:$activation,backend:$backend,revision:$revision,
      resolvedRevision:$resolvedRevision,dirty:$dirty,repository:$repository,
      windowsPlan:$windowsPlan,mutationBoundary:$mutationBoundary}')"
  if [[ "$preview_json" == 0 ]]; then
    if [[ "$json" == 1 ]]; then
      printf '%s\n' "$output"
    else
      jq -r '"host: \(.host)\ninstallable: \(.installable)\nsource: \(.source)\nsystem: \(.system)\nuser: \(.user)\nhome: \(.homeDirectory)\nidentity: \(.identityMode)\ncapabilities: \(.capabilities | join(", "))\nactivation: \(.activation)\nbackend: \(.backend)\nrevision: \(.revision)\ndirty: \(.dirty)\nmutation boundary: \(.mutationBoundary)"' <<<"$output"
      [[ "$activation" != nixos-wsl ]] || windows_render_plan "$windows_preflight"
    fi
  fi
  if [[ "$activation" == nixos-wsl ]] && ! jq -e '.ready' <<<"$windows_preflight" >/dev/null; then
    return "$EX_UNAVAILABLE"
  fi
  [[ "$plan" == 0 ]] || return 0

  local activation_flake_source="$flake_source" adapter_dir="" adapter_source="$flake_source"
  if [[ "$identity_mode" == runtime ]]; then
    [[ "$source" != local ]] || adapter_source="path:$flake_source"
    adapter_dir="$(create_runtime_adapter "$host" "$data" "$adapter_source" "$git_auth_mode")"
    activation_flake_source="path:$adapter_dir"
    trap '[[ -z "${adapter_dir:-}" ]] || rm -rf -- "$adapter_dir"' EXIT
  fi

  local -a nh_args
  local nh_command=nh
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_NH:-}" ]]; then
    nh_command="$ATYRODE_NH"
  fi
  # SSH commonly forwards macOS's LC_CTYPE=UTF-8 spelling, which Linux does
  # not recognize. nom then falls back to ASCII and cannot decode UTF-8
  # derivation metadata. Keep the backend on a platform-native UTF-8 locale.
  local nh_locale=C.UTF-8
  [[ "$expected_system" != *-darwin ]] || nh_locale=en_US.UTF-8
  # nh home passes a #fragment through to nix verbatim instead of treating
  # it as the configuration name, so the flake reference goes bare and
  # --configuration carries the host. System owners resolve the fragment.
  case "$activation" in
    home-manager)
      nh_args=("$nh_command" home switch "$activation_flake_source" --configuration "$host" --backup-extension backup --diff always)
      ;;
    nix-darwin) nh_args=("$nh_command" darwin switch "$installable" --diff always) ;;
    nixos-wsl) nh_args=("$nh_command" os switch "$installable" --diff always) ;;
  esac
  [[ "$dry" == 0 ]] || nh_args+=(--dry)
  if [[ "$preview_json" == 1 ]]; then
    [[ -x "$atyrode_preview_parser" ]] || die "$EX_UNAVAILABLE" "atyrode preview parser is unavailable"
    local preview_file preview_output
    preview_file="$(mktemp)"
    if ! LC_ALL="$nh_locale" "${nh_args[@]}" >"$preview_file" 2>&1; then
      cat "$preview_file" >&2
      rm -f "$preview_file"
      die "$EX_SOFTWARE" "$backend preview failed"
    fi
    if ! preview_output="$("$atyrode_preview_parser" --host "$host" --system "$expected_system" --revision "$resolved_revision" <"$preview_file")"; then
      rm -f "$preview_file"
      die "$EX_SOFTWARE" "$backend preview output was not understood"
    fi
    rm -f "$preview_file"
    if [[ "$activation" == nixos-wsl ]]; then
      jq -c --argjson windowsPlan "$windows_preflight" \
        '. + {windowsPlan:$windowsPlan,windowsTransactional:false}' <<<"$preview_output"
    else
      printf '%s\n' "$preview_output"
    fi
    [[ -z "$adapter_dir" ]] || rm -rf -- "$adapter_dir"
    trap - EXIT
    return 0
  fi
  LC_ALL="$nh_locale" "${nh_args[@]}" || die "$EX_SOFTWARE" "$backend activation failed"
  [[ -z "$adapter_dir" ]] || rm -rf -- "$adapter_dir"
  trap - EXIT
  if [[ "$dry" == 0 ]]; then
    local state_dir state_file temp
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/atyrode"
    state_file="$state_dir/dotfiles-config"
    mkdir -p "$state_dir"
    temp="$(mktemp "$state_dir/.dotfiles-config.XXXXXX")"
    printf '%s\n' "$host" >"$temp"
    mv -f "$temp" "$state_file"
    if [[ "$identity_mode" == runtime ]]; then
      local git_auth_mode_file="$state_dir/git-auth-mode"
      [[ ! -L "$git_auth_mode_file" ]] ||
        die "$EX_DATAERR" "persisted Git auth mode must not be a symlink"
      temp="$(mktemp "$state_dir/.git-auth-mode.XXXXXX")"
      printf '%s\n' "$git_auth_mode" >"$temp"
      chmod 600 "$temp"
      mv -f "$temp" "$git_auth_mode_file"
    fi
    if [[ "$activation" == nixos-wsl ]]; then
      local windows_result
      if ! windows_result="$(windows_reconcile apply "$host" 1)"; then
        die "$EX_SOFTWARE" "NixOS activation succeeded, but the non-transactional Windows phase failed; rerun 'atyrode windows apply'"
      fi
      [[ "$json" == 1 ]] || windows_render_plan "$windows_result"
    fi
    # Declared state first, decisions second. Convergence is not a question:
    # the login shell is part of what this host says it is, so apply fixes it
    # rather than reporting it. Only then are the opt-in surfaces raised, so a
    # machine that is still wrong never gets asked what else it would like.
    converge_login_shell "$host" || apply_status="$EX_UNAVAILABLE"
    review_provisioning "$json" "$host"
    # apply owns removing packages from the environment, not reclaiming their
    # residue; surface the follow-up so dropped apps don't linger on disk.
    if [[ "$json" == 0 && -t 1 ]]; then
      printf 'atyrode: reclaim old generations + dropped-app residue with: atyrode clean\n' >&2
    fi
  fi
  if [[ "$restart" == 1 ]]; then
    local shell_path=/run/current-system/sw/bin/zsh
    [[ "$activation" != home-manager ]] || shell_path="$expected_home/.nix-profile/bin/zsh"
    printf 'Activation completed. Restart the current shell with: exec %q -l\n' "$shell_path" >&2
  fi
  return "$apply_status"
}

# The login shell is declared state: inventory/system-boundary.json names the
# path this host's Zsh must be, and `doctor system` already reports when the
# account database disagrees. Reporting was the whole problem -- its
# remediation used to be "rerun install.sh apply", which is a tool that runs on
# every machine forever deferring to one that runs once. Apply converges it
# instead, on every run, so the state heals wherever it drifts.
#
# Only the owner apply can answer for is converged here. nix-darwin sets the
# primary account's UserShell during activation and NixOS sets it from the
# system closure; if either still disagrees afterwards, the fix belongs in that
# configuration and saying so is the honest response. The home-manager case has
# no such owner, which is exactly why the bootstrap grew one.
converge_login_shell() { # host
  local host="$1" diagnostics owner status target user shells_file=/etc/shells

  diagnostics="$(doctor_system "$host" --json 2>/dev/null)" || true
  [[ -n "$diagnostics" ]] || return 0
  owner="$(jq -r '.checks[]|select(.id=="login-shell")|.owner' <<<"$diagnostics")"
  status="$(jq -r '.checks[]|select(.id=="login-shell")|.status' <<<"$diagnostics")"
  [[ "$status" == incomplete ]] || return 0
  target="$(jq -r '.checks[]|select(.id=="login-shell")|.expected.path' <<<"$diagnostics")"

  if [[ "$owner" != atyrode ]]; then
    printf 'atyrode: the account login shell is not %s, and %s owns it here\n' \
      "$target" "$owner" >&2
    printf 'atyrode: fix it in that configuration; apply cannot answer for it\n' >&2
    return 0
  fi

  user="$(id -un)"
  if [[ ! -x "$target" ]]; then
    printf 'atyrode: the managed Zsh is not executable at %s\n' "$target" >&2
    return 1
  fi
  if [[ ! -f "$shells_file" || -L "$shells_file" ]]; then
    printf 'atyrode: %s must be a regular file to register a login shell\n' "$shells_file" >&2
    return 1
  fi
  printf 'atyrode: selecting %s as the login shell for %s\n' "$target" "$user" >&2
  if ! grep -Fqx -- "$target" "$shells_file"; then
    # shellcheck disable=SC2016 # Positional parameters expand in the privileged shell.
    run_privileged sh -c 'grep -Fqx -- "$1" "$2" || printf "%s\n" "$1" >> "$2"' \
      sh "$target" "$shells_file" || {
      printf 'atyrode: could not register the managed Zsh in %s\n' "$shells_file" >&2
      return 1
    }
  fi
  command -v chsh >/dev/null 2>&1 || {
    printf 'atyrode: chsh is unavailable, so the account database cannot be updated\n' >&2
    return 1
  }
  run_privileged chsh -s "$target" "$user" || {
    printf 'atyrode: chsh could not update the account database\n' >&2
    return 1
  }
  # Ask the same probe again rather than trusting the write: chsh can report
  # success on a platform that stores the change somewhere the account database
  # does not read back.
  diagnostics="$(doctor_system "$host" --json 2>/dev/null)" || true
  if [[ "$(jq -r '.checks[]|select(.id=="login-shell")|.status' <<<"$diagnostics")" != ok ]]; then
    printf 'atyrode: the account login shell still is not %s\n' "$target" >&2
    return 1
  fi
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -- "$@"
  else
    printf 'atyrode: sudo is required for this step and is unavailable\n' >&2
    return 1
  fi
}
