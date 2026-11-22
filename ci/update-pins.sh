#!/usr/bin/env bash
# Refresh selected repository-owned binary pins to their latest releases.
# With no package names, refresh OMP and Codex. Prints one line per
# bump on stdout -- the manifest the workflow reads -- and narrates what it
# fetched and rewrote on stderr. Requires curl, jq, awk, and nix.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Nothing packages this script; it is run out of a checkout, by hand as
# `./ci/update-pins.sh omp` and by the update-pins workflow. There is
# therefore no wrapper to hand it the shared voice, so it finds the library
# beside itself in the tree, while still deferring to an ATYRODE_NARRATE a
# future caller sets. Only an unset variable falls back: one deliberately set
# to nothing is a wiring mistake and gets the refusal below rather than a
# silent substitution.
: "${ATYRODE_NARRATE=$repo_root/pkgs/atyrode/lib/narrate.sh}"
# shellcheck source=/dev/null
. "${ATYRODE_NARRATE:?the narration library was not provided}"
NARRATE_NAME=update-pins

targets=("$@")
for target in "${targets[@]}"; do
  case "$target" in
    omp | codex) ;;
    *)
      refuse "$NARRATE_NAME" "$target is not a pin this repository owns"
      say "usage: ${0##*/} [omp|codex]..."
      exit 2
      ;;
  esac
done

wants() {
  [[ "${#targets[@]}" -eq 0 ]] && return 0
  local target
  for target in "${targets[@]}"; do
    [[ "$target" == "$1" ]] && return 0
  done
  return 1
}

# The token is a secret and this fetch is announced, so it cannot ride in a
# header on the command line: curl reads it from a config on stdin, and what
# the operator sees is the request without the credential attached.
latest_tag() { # repo
  local url="https://api.github.com/repos/$1/releases/latest"
  show_command curl -fsSL "$url"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
      curl -fsSL --config - "$url"
  else
    curl -fsSL "$url"
  fi | jq -er .tag_name
}

current_version() {
  sed -nE 's/^[[:space:]]*version = "([^"]+)";$/\1/p' "$1" | head -n 1
}

replace_hash() { # file asset new_hash
  # The rewrite is an awk program, not a command anyone would paste back, so
  # the write reports itself in prose and the temp file it swaps through stays
  # out of the transcript.
  say "pinning $2 to $3"
  awk -v asset="$2" -v hash="$3" '
    index($0, "\"" asset "\"") { pending = 1 }
    pending && $1 == "hash" { sub(/sha256-[A-Za-z0-9+\/=]+/, hash); pending = 0 }
    { print }
  ' "$1" >"$1.bump" && mv "$1.bump" "$1"
}

bump() { # name file repo tag_prefix url_template assets...
  local name="$1" file="$2" repo="$3" tag_prefix="$4" url_template="$5"
  shift 5
  local current version tag tmp asset url hash
  current="$(current_version "$file")"
  tag="$(latest_tag "$repo")"
  version="${tag#"$tag_prefix"}"
  if [[ "$version" == "$current" ]]; then
    say "$name is current at $current"
    return 0
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  say "rewriting ${file#"$repo_root"/} from $current to $version"
  run_visible sed -i "s/version = \"$current\"/version = \"$version\"/" "$file"
  for asset in "$@"; do
    url="${url_template//@tag@/$tag}"
    url="${url//@asset@/$asset}"
    run_visible curl -fsSL "$url" -o "$tmp/${asset//\//-}"
    hash="$(nix hash file --sri "$tmp/${asset//\//-}")"
    replace_hash "$file" "$asset" "$hash"
  done
  printf '%s %s -> %s\n' "$name" "$current" "$version"
}

if wants omp; then
  bump omp "$repo_root/pkgs/omp/default.nix" can1357/oh-my-pi v \
    'https://github.com/can1357/oh-my-pi/releases/download/@tag@/@asset@' \
    omp-linux-x64 omp-linux-arm64 omp-darwin-x64 omp-darwin-arm64
fi

if wants codex; then
  bump codex "$repo_root/pkgs/codex/default.nix" openai/codex rust-v \
    'https://github.com/openai/codex/releases/download/@tag@/@asset@.tar.gz' \
    codex-aarch64-apple-darwin codex-x86_64-unknown-linux-musl codex-aarch64-unknown-linux-musl
fi
