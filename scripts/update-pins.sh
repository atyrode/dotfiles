#!/usr/bin/env bash
# Refresh the repository-owned binary pins (OMP, code, Codex, Orca, and herdr)
# to their latest upstream releases. Prints one line per bumped package; exits
# quietly when everything is already current. Requires curl, jq, awk, and nix.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

latest_tag() {
  curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$1/releases/latest" | jq -er .tag_name
}

current_version() {
  grep -oE 'version = "[0-9.]+"' "$1" | head -n 1 | grep -oE '[0-9.]+'
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

bump omp "$repo_root/pkgs/omp/default.nix" can1357/oh-my-pi v \
  'https://github.com/can1357/oh-my-pi/releases/download/@tag@/@asset@' \
  omp-linux-x64 omp-linux-arm64 omp-darwin-x64 omp-darwin-arm64

bump code "$repo_root/pkgs/code/default.nix" atyrode/code v \
  'https://github.com/atyrode/code/releases/download/@tag@/@asset@.tar.gz' \
  code-linux-amd64 code-linux-arm64 code-darwin-amd64 code-darwin-arm64

bump codex "$repo_root/pkgs/codex-bin/default.nix" openai/codex rust-v \
  'https://github.com/openai/codex/releases/download/@tag@/@asset@.tar.gz' \
  codex-aarch64-apple-darwin codex-x86_64-unknown-linux-musl codex-aarch64-unknown-linux-musl

bump orca "$repo_root/pkgs/orca-ide/default.nix" stablyai/orca v \
  'https://github.com/stablyai/orca/releases/download/@tag@/@asset@' \
  orca-linux.AppImage orca-linux-arm64.AppImage orca-macos-x64.dmg orca-macos-arm64.dmg

bump herdr "$repo_root/pkgs/herdr/default.nix" ogulcancelik/herdr v \
  'https://github.com/ogulcancelik/herdr/releases/download/@tag@/@asset@' \
  herdr-linux-x86_64 herdr-linux-aarch64 herdr-macos-x86_64 herdr-macos-aarch64

# The vendored herdr skill (agents/skills/herdr/SKILL.md) is reviewed agent
# instructions sourced from a public repository; it is never overwritten
# automatically. Point at the upstream diff whenever it lags the pin —
# checks/herdr.nix fails CI on the same mismatch, so a herdr bump PR cannot
# land without the reviewed skill refresh.
herdr_pin="$(current_version "$repo_root/pkgs/herdr/default.nix")"
herdr_skill="$(grep -oE 'HERDR_SKILL_UPSTREAM_VERSION=[0-9.]+' \
  "$repo_root/agents/skills/herdr/SKILL.md" | grep -oE '[0-9.]+$')"
if [[ "$herdr_pin" != "$herdr_skill" ]]; then
  printf 'herdr skill vendored at %s lags pin %s: review https://github.com/ogulcancelik/herdr/blob/v%s/SKILL.md, then update agents/skills/herdr/SKILL.md\n' \
    "$herdr_skill" "$herdr_pin" "$herdr_pin"
fi

# Orca's three reviewed skills are kept at the same release as its package.
# checks/orca.nix deliberately blocks an automatic package bump until all three
# instruction files have been reviewed and refreshed.
orca_pin="$(current_version "$repo_root/pkgs/orca-ide/default.nix")"
orca_skill="$(grep -hoE 'ORCA_SKILL_UPSTREAM_VERSION=[0-9.]+' \
  "$repo_root/agents/skills/orca-cli/SKILL.md" \
  "$repo_root/agents/skills/orchestration/SKILL.md" \
  "$repo_root/agents/desktop-skills/computer-use/SKILL.md" |
  grep -oE '[0-9.]+$' | sort -u)"
if [[ "$orca_pin" != "$orca_skill" ]]; then
  printf 'Orca skills vendored at %s lag pin %s: review https://github.com/stablyai/orca/tree/v%s/skills, then refresh orca-cli, orchestration, and computer-use\n' \
    "$orca_skill" "$orca_pin" "$orca_pin"
fi
