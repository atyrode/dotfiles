# shellcheck shell=bash
#
# Generations: the clean that reclaims them and the rollback that reactivates one.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# On macOS, home-manager links GUI apps into ~/Applications/Home Manager Apps as
# symlinks into the store. When a package is dropped it sometimes leaves the link
# behind pointing at a garbage-collected target (a broken symlink) — the stale
# "Visual Studio Code.app" kind of leftover. Removing a link is safe and
# reversible (the next apply recreates the valid ones); app *data* is app-owned
# and Nix never managed it, so we only point at it.
clean_macos_residue() {
  local dry="$1" assume_yes="$2"
  local hm_apps="$HOME/Applications/Home Manager Apps"
  [[ -d "$hm_apps" ]] || return 0
  local -a stale=()
  local f
  while IFS= read -r f; do
    [[ -e "$f" ]] || stale+=("$f") # a link whose store target is gone
  done < <(find "$hm_apps" -mindepth 1 -maxdepth 1 -type l)
  if [[ "${#stale[@]}" -eq 0 ]]; then
    printf 'atyrode: no stale Home Manager Apps aliases.\n' >&2
  else
    printf 'atyrode: %s stale app alias(es) left by removed packages:\n' "${#stale[@]}" >&2
    for f in "${stale[@]}"; do printf '  %s\n' "$(basename "$f")" >&2; done
    for f in "${stale[@]}"; do
      [[ -L "$f" && "$f" == "$hm_apps/"* ]] || continue # never touch anything but a link under this dir
      if [[ "$dry" == 1 ]]; then
        printf '  would remove: %s\n' "$(basename "$f")" >&2
      elif [[ "$assume_yes" == 1 ]] || confirm "remove stale alias $(basename "$f")?"; then
        rm -f "$f" && printf '  removed %s\n' "$(basename "$f")" >&2
      fi
    done
  fi
  printf 'atyrode: note — app data (e.g. ~/Library/Application Support/<App>) is\n' >&2
  printf '  app-owned, not Nix-managed, so a dropped app leaves it behind; remove by hand.\n' >&2
}

# clean — reclaim disk from generations the configuration no longer references.
# nh owns the retention policy's mechanics: it keeps the current generation, the
# newest --keep and everything newer than --keep-since, drops the rest together
# with the GC roots that pinned them, and collects the store. atyrode adds only
# what nh cannot know: which profiles this machine's activation owns (every
# profile on NixOS and nix-darwin, one user's on standalone Home Manager) and,
# on macOS, the stale app aliases a dropped package leaves behind.
cmd_clean() {
  local dry=0 keep=5 keep_since=30d assume_yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --dry-run) dry=1 ;;
      --keep)
        shift
        keep="${1:-}"
        ;;
      --keep-since)
        shift
        keep_since="${1:-}"
        ;;
      -y | --yes) assume_yes=1 ;;

      *) die "$EX_USAGE" "unknown clean option: $1" ;;
    esac
    shift || true
  done
  [[ "$keep" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "--keep expects a number"
  command -v nh >/dev/null || die "$EX_UNAVAILABLE" "nh is unavailable"
  local nh_command=nh
  [[ "$test_hooks" != 1 || -z "${ATYRODE_NH:-}" ]] || nh_command="$ATYRODE_NH"

  local scope=all
  [[ "$(jq -r '.activation' <<<"$(host_json "$(resolve_host "")")")" != home-manager ]] || scope=user
  local -a nh_args=("$nh_command" clean "$scope" --keep "$keep" --keep-since "$keep_since")
  [[ "$dry" == 0 ]] || nh_args+=(--dry)
  # nh prints its plan and asks before removing anything, so an accidental run
  # can still be read and declined; --yes is the explicit non-interactive path
  # and a dry run has nothing to ask about.
  [[ "$dry" == 1 || "$assume_yes" == 1 ]] || nh_args+=(--ask)
  run_visible "${nh_args[@]}" || return $?

  [[ "$(uname -s)" != Darwin ]] || clean_macos_residue "$dry" "$assume_yes"
}

# The activation profile whose generations `apply` switches. NixOS-WSL and
# nix-darwin own system profiles; standalone Linux owns Home Manager's profile.
gen_platform() {
  if [[ "$(uname -s)" == Darwin ]]; then
    printf 'nix-darwin'
  elif is_wsl; then
    printf 'nixos'
  else
    printf 'home-manager'
  fi
}

gen_profile() {
  if [[ "$test_hooks" == 1 && -n "${ATYRODE_GEN_PROFILE:-}" ]]; then
    printf '%s' "$ATYRODE_GEN_PROFILE" # pin the profile path in tests (platform-agnostic)
    return
  fi
  case "$(gen_platform)" in
    nix-darwin | nixos) printf '/nix/var/nix/profiles/system' ;;
    home-manager) printf '%s/nix/profiles/home-manager' "${XDG_STATE_HOME:-$HOME/.local/state}" ;;
  esac
}

# rollback — activate an earlier generation (previous by default, or --to N).
# A mutation, so it confirms first and --dry-run only previews; roll-forward is
# always possible, and it refuses to "roll back" to the current generation.
# An earlier generation is a candidate like any other: what its activation
# does to services is analysed against the generation running now and refused
# on the same terms as apply, because the agent that owns every terminal does
# not care which direction the generation that stops it came from.
cmd_rollback() {
  local to="" dry=0 assume_yes=0 expected_disruption="" requested=""
  local -a scopes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        shift
        to="${1:-}"
        ;;
      --expected-disruption)
        shift
        expected_disruption="${1:-}"
        [[ "$expected_disruption" =~ ^[0-9a-f]{64}$ ]] ||
          die "$EX_USAGE" "--expected-disruption expects the 64-hex fingerprint printed by rollback --dry-run"
        ;;
      --scope)
        shift
        [[ -n "${1:-}" ]] || die "$EX_USAGE" "--scope requires scope:service"
        validate_scope "$1"
        scopes+=("$1")
        ;;
      -n | --dry-run) dry=1 ;;
      -y | --yes) assume_yes=1 ;;
      --*) die "$EX_USAGE" "unknown rollback option: $1" ;;
      *)
        [[ -z "$requested" ]] || die "$EX_USAGE" "rollback accepts at most one host"
        requested="$1"
        ;;
    esac
    shift || true
  done
  command -v nix-env >/dev/null || die "$EX_UNAVAILABLE" "nix-env is unavailable"
  local profile platform activation
  profile="$(gen_profile)"
  platform="$(gen_platform)"
  [[ -e "$profile" ]] || die "$EX_NOINPUT" "no $platform generations profile at $profile"
  case "$platform" in
    nix-darwin) activation=nix-darwin ;;
    nixos) activation=nixos ;;
    *) activation=home-manager ;;
  esac

  local listing current target
  # A failed read must not exit 1 with no diagnostic under `set -e`; the
  # refusals below are the useful output, so surface an unreadable profile.
  listing="$(nix_env -p "$profile" --list-generations 2>/dev/null)" ||
    die "$EX_UNAVAILABLE" "cannot read the $platform generations profile at $profile"
  current="$(awk '/\(current\)/{print $1}' <<<"$listing")"
  [[ -n "$current" ]] || die "$EX_SOFTWARE" "cannot determine the current generation"
  if [[ -n "$to" ]]; then
    [[ "$to" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "--to expects a generation number"
    target="$to"
    awk '{print $1}' <<<"$listing" | grep -qx "$target" || die "$EX_DATAERR" "generation $target does not exist"
  else
    target="$(awk -v c="$current" '$1+0 < c+0 {g=$1} END{print g}' <<<"$listing")"
    [[ -n "$target" ]] || die "$EX_UNAVAILABLE" "no earlier generation to roll back to"
  fi
  [[ "$target" != "$current" ]] || die "$EX_USAGE" "generation $target is already current"

  local genpath
  genpath="$(readlink -f "$profile-$target-link" 2>/dev/null)" ||
    die "$EX_DATAERR" "cannot resolve generation $target"
  printf 'atyrode: roll %s back from generation %s to %s\n' "$platform" "$current" "$target" >&2

  # The lock is held from here through the activation, so the generation the
  # report describes is the one still running when the switch begins; a dry
  # run holds nothing, since it changes nothing. A NixOS rollback runs under
  # sudo, which drops the receipt and the environment apply resolves the host
  # from, so the host may be named on the command line; the operator whose
  # Home Manager units the report labels is the account that invoked sudo.
  [[ "$dry" == 1 ]] || activation_lock
  local running report host operator
  host="$(resolve_host "$requested")"
  operator="${SUDO_USER:-$(actual_user)}"
  running="$(current_generation "$activation" "$operator")" ||
    die "$EX_UNAVAILABLE" "the generation running now cannot be named, so generation $target cannot be shown safe against it"
  report="$(disruption_analyze "$host" "$activation" "$running" "$genpath" "$operator" "${scopes[@]+"${scopes[@]}"}")" ||
    die "$EX_UNAVAILABLE" "the disruption analyzer did not produce a report, and a rollback without one cannot be shown safe"
  disruption_render "$report"
  if [[ "$dry" == 1 ]]; then
    printf '  dry run — nothing activated\n' >&2
    return 0
  fi
  disruption_enforce "$report" "$expected_disruption" "$genpath"
  [[ "$assume_yes" == 1 ]] || confirm "activate generation $target now?" || return 0

  # Activating a generation is the same class of change `apply` makes, and apply
  # shows its argv: the confirm above answered "may I", the commands below answer
  # "with what".
  if [[ "$platform" == nix-darwin ]]; then
    command -v darwin-rebuild >/dev/null || die "$EX_UNAVAILABLE" "darwin-rebuild is unavailable"
    # darwin-rebuild owns its own privilege elevation (as nh does for apply);
    # atyrode never self-elevates. Run `sudo atyrode rollback` if a setup needs it.
    run_visible darwin-rebuild --switch-generation "$target" || die "$EX_SOFTWARE" "rollback failed"
  elif [[ "$platform" == nixos ]]; then
    [[ "$(effective_uid)" == 0 ]] ||
      die "$EX_UNAVAILABLE" "NixOS rollback requires root; rerun this exact command with sudo"
    [[ -x "$genpath/bin/switch-to-configuration" ]] ||
      die "$EX_DATAERR" "generation $target has no NixOS switch-to-configuration program"
    # Resolved rather than run through core's nix_env wrapper: an announced
    # command has to be one an operator can paste back, and a shell function name
    # is not a program.
    local nix_env_command=nix-env
    [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX_ENV:-}" ]] || nix_env_command="$ATYRODE_NIX_ENV"
    run_visible "$nix_env_command" -p "$profile" --switch-generation "$target" ||
      die "$EX_SOFTWARE" "could not select NixOS generation $target"
    run_visible "$profile/bin/switch-to-configuration" switch ||
      die "$EX_SOFTWARE" "NixOS rollback activation failed"
  else
    [[ -x "$genpath/activate" ]] || die "$EX_DATAERR" "generation $target has no activate script"
    run_visible "$genpath/activate" || die "$EX_SOFTWARE" "rollback activation failed"
  fi
  printf 'atyrode: now on generation %s\n' "$target" >&2
}
