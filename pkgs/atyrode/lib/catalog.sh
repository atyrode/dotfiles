# shellcheck shell=bash
#
# The catalog: software the operator vouches for but does not want on any
# machine, launched for the length of one invocation and never declared.
#
# Sourced by bin/atyrode; every @substitution@ lives in that entry point.

# The catalog is reviewed data baked in at build time exactly as the host
# registry is, so the answer to "what may I run" is a property of this binary's
# revision rather than of the checkout it happens to sit next to. A build that
# has not baked one yet leaves the placeholder unsubstituted, which is an empty
# catalog and not a broken machine.
catalog_json() {
  [[ -f "$catalog" ]] || {
    printf '{}\n'
    return
  }
  jq -c . "$catalog" || die "$EX_DATAERR" "the baked catalog at $catalog is not readable JSON"
}

catalog_entry_names() { jq -r 'keys | join(", ")' <<<"$1"; }

catalog_render_list() { # catalog
  local catalog_data="$1" system width name reason systems
  if [[ "$(jq -r 'length' <<<"$catalog_data")" == 0 ]]; then
    printf 'the catalog is empty\n'
    return
  fi
  system="$(actual_system)"
  printf 'software this CLI can run without installing it\n'
  width="$(jq -r '[keys[] | length] | max' <<<"$catalog_data")"
  # An entry that cannot run here is still listed, because the catalog is the
  # operator's own note about what is worth having and reads the same on every
  # machine; what changes is that this machine is named as unable to run it.
  while IFS=$'\t' read -r name reason systems; do
    printf '  %-*s  %s' "$width" "$name" "$reason"
    [[ -z "$systems" ]] || printf ' (runs on %s, not on this %s)' "$systems" "$system"
    printf '\n'
  done < <(jq -r --arg system "$system" '
    to_entries | sort_by(.key) | .[]
    | [ .key, .value.reason,
        (if any(.value.systems[]; . == $system) then "" else (.value.systems | join(", ")) end) ]
    | @tsv' <<<"$catalog_data")
  printf '\nnothing here is installed and no generation records it: a run leaves no\n'
  printf 'GC root, so atyrode clean is the whole return path\n'
}

catalog_nix_program() {
  local program=nix
  [[ "$test_hooks" != 1 || -z "${ATYRODE_NIX:-}" ]] || program="$ATYRODE_NIX"
  printf '%s\n' "$program"
}

catalog_launch() { # attribute argv...
  local attribute="$1"
  shift
  local command=("$(catalog_nix_program)" run "nixpkgs#$attribute")
  [[ $# == 0 ]] || command+=(-- "$@")
  show_command "${command[@]}"
  # The program replaces this one, so it behaves exactly as the announced
  # command would: its output goes wherever the caller's does, Ctrl-C stops it,
  # and its exit status is the one the caller reads. Backgrounding a windowed
  # program is the caller's decision and the shell already has a verb for it;
  # making it here would mean deciding, without being able to know, that the
  # output of a terminal program was not the point.
  exec "${command[@]}"
}

cmd_run() {
  local json=0 list=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
        shift
        ;;
      --list)
        list=1
        shift
        ;;
      -*) die "$EX_USAGE" "unknown run option: $1" ;;
      # The name ends our options and begins the program's: everything after it
      # belongs to the entry, so `run rg --json` searches rather than reporting.
      *)
        name="$1"
        shift
        break
        ;;
    esac
  done

  local catalog_data
  catalog_data="$(catalog_json)"

  if [[ -z "$name" ]]; then
    [[ $# == 0 ]] || die "$EX_USAGE" "run expects the entry to launch before its arguments"
    if [[ "$json" == 1 ]]; then
      printf '%s\n' "$catalog_data"
    else
      catalog_render_list "$catalog_data"
    fi
    return
  fi
  [[ "$json" == 0 && "$list" == 0 ]] || die "$EX_USAGE" "run $name launches an entry; --list and --json print the catalog and take no name"
  # A conventional separator before the entry's own flags, so an argument that
  # would otherwise be read as one of ours can be passed through.
  [[ "${1:-}" != -- ]] || shift

  local entry
  entry="$(jq -c --arg name "$name" '.[$name] // empty' <<<"$catalog_data")"
  if [[ -z "$entry" ]]; then
    local known
    known="$(catalog_entry_names "$catalog_data")"
    [[ -n "$known" ]] || die "$EX_USAGE" "the catalog is empty, so there is nothing named $name to run"
    die "$EX_USAGE" "unknown catalog entry: $name; the catalog holds $known"
  fi

  local attribute system
  attribute="$(jq -r '.attribute // ""' <<<"$entry")"
  [[ -n "$attribute" ]] || die "$EX_DATAERR" "catalog entry $name names no nixpkgs attribute"
  system="$(actual_system)"
  if ! jq -e --arg system "$system" 'any(.systems[]; . == $system)' >/dev/null <<<"$entry"; then
    local systems remedy=""
    systems="$(jq -r '.systems | join(", ")' <<<"$entry")"
    # On a Mac the refusal has somewhere to send the operator, because the same
    # program is usually declared rather than run: a cask is installed by
    # activation and there is no ephemeral form of one to offer instead.
    [[ "$system" != *-darwin ]] || remedy="; macOS GUI software is declared as a Homebrew cask (modules/darwin/casks.nix) and installed by apply, because a cask cannot be run ephemerally"
    die "$EX_UNAVAILABLE" "$name runs on $systems, not on this machine's $system$remedy"
  fi

  catalog_launch "$attribute" "$@"
}
