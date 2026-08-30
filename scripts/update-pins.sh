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

# Reports a bump this run declined to make. Cron reruns are unattended, so a
# hold must be visible where someone will actually see it: the job summary when
# running in Actions, stderr otherwise. It never lands on stdout, which is the
# bump manifest the workflow reads to decide whether to open a pull request.
hold() { # name reason
  printf 'holding %s bump: %s\n' "$1" "$2" >&2
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] ||
    printf -- '- holding %s bump: %s\n' "$1" "$2" >>"$GITHUB_STEP_SUMMARY"
}

# Manifold is the one pin whose upgrade ORDER is load-bearing. The hub accepts
# older agent protocol versions but can never accept a newer one — it closes the
# dial 4409 — and that lockout is invisible to systemd: the agent process stays
# healthy and re-dials forever, so the machine simply vanishes from the canvas.
# On 2026-08-30 an unattended refresh to 0.5.0 (protocol 13) against a v0.4.4
# hub (protocol 4) took a spoke off the canvas exactly that way.
# docs/manifold.md "Upgrades" makes hub-first an operator-timed step; this guard
# makes the six-hourly cron obey it. Fails closed: anything it cannot prove
# holds the bump.
guard_manifold() { # tag version repo
  local tag="$1" version="$2" repo="$3" master_url hub candidate
  if ! master_url="$(jq -er .masterUrl "$repo_root/inventory/manifold.json")"; then
    hold manifold "inventory/manifold.json declares no masterUrl"
    return 1
  fi
  if ! hub="$(curl -fsSL --max-time 20 "$master_url/healthz" | jq -er .protocolVersion)"; then
    hold manifold "hub $master_url is unreachable, so $version cannot be cleared"
    return 1
  fi
  # Read the candidate's protocol version from its tagged source rather than by
  # running the asset: the number is a source constant, and a pin refresh must
  # never execute an unvetted binary to decide whether to pin it.
  candidate="$(curl -fsSL --max-time 20 \
    "https://raw.githubusercontent.com/$repo/$tag/packages/protocol/src/version.ts" |
    sed -nE 's/^export const PROTOCOL_VERSION = ([0-9]+);$/\1/p' | head -n 1)" || candidate=""
  if [[ ! "$candidate" =~ ^[0-9]+$ ]]; then
    hold manifold "cannot read PROTOCOL_VERSION from $tag"
    return 1
  fi
  if [[ "$candidate" -gt "$hub" ]]; then
    hold manifold \
      "$version speaks protocol $candidate but the hub serves $hub; deploy the hub first (docs/manifold.md)"
    return 1
  fi
}

bump() { # name file repo tag_prefix url_template assets...
  local name="$1" file="$2" repo="$3" tag_prefix="$4" url_template="$5"
  shift 5
  local current version tag tmp asset url hash
  current="$(current_version "$file")"
  tag="$(latest_tag "$repo")"
  version="${tag#"$tag_prefix"}"
  [[ "$version" != "$current" ]] || return 0
  # A per-target precondition, declared as guard_<name>. Bumps without one are
  # unordered by construction and stay unconditional.
  if declare -F "guard_$name" >/dev/null && ! "guard_$name" "$tag" "$version" "$repo"; then
    return 0
  fi
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
  bump manifold "$repo_root/pkgs/manifold-agent/default.nix" atyrode/manifold v \
    'https://github.com/atyrode/manifold/releases/download/@tag@/@asset@' \
    manifold-agent-linux-x64
fi
