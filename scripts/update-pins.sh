#!/usr/bin/env bash
# Refresh selected repository-owned binary pins to their latest releases.
# With no package names, refresh OMP, code, and Codex. Prints one line
# per bump; exits quietly when current. Requires curl, jq, awk, and nix.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

targets=("$@")
for target in "${targets[@]}"; do
  case "$target" in
    omp | code | codex | manifold) ;;
    *)
      printf 'usage: %s [omp|code|codex|manifold]...\n' "${0##*/}" >&2
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

latest_tag() {
  curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$1/releases/latest" | jq -er .tag_name
}

current_version() {
  sed -nE 's/^[[:space:]]*version = "([^"]+)";$/\1/p' "$1" | head -n 1
}

replace_hash() { # file asset new_hash
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
  [[ "$version" != "$current" ]] || return 0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  sed -i "s/version = \"$current\"/version = \"$version\"/" "$file"
  for asset in "$@"; do
    url="${url_template//@tag@/$tag}"
    url="${url//@asset@/$asset}"
    curl -fsSL "$url" -o "$tmp/${asset//\//-}"
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

if wants code; then
  bump code "$repo_root/pkgs/code/default.nix" atyrode/code v \
    'https://github.com/atyrode/code/releases/download/@tag@/@asset@.tar.gz' \
    code-linux-amd64 code-linux-arm64 code-darwin-amd64 code-darwin-arm64
fi

if wants codex; then
  bump codex "$repo_root/pkgs/codex/default.nix" openai/codex rust-v \
    'https://github.com/openai/codex/releases/download/@tag@/@asset@.tar.gz' \
    codex-aarch64-apple-darwin codex-x86_64-unknown-linux-musl codex-aarch64-unknown-linux-musl
fi

if wants manifold; then
  # The manifold agent is a pinned flake input, not a release-asset pin:
  # bump the tag in flake.nix, then relock that single input.
  flake="$repo_root/flake.nix"
  current_tag="$(sed -nE 's|.*github:atyrode/manifold/([^"]+)".*|\1|p' "$flake" | head -n 1)"
  tag="$(latest_tag atyrode/manifold)"
  if [[ "$tag" != "$current_tag" ]]; then
    sed -i "s|github:atyrode/manifold/$current_tag|github:atyrode/manifold/$tag|" "$flake"
    nix flake update manifold --flake "$repo_root"
    printf 'manifold %s -> %s\n' "$current_tag" "$tag"
  fi
fi
