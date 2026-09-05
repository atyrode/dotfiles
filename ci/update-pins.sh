#!/usr/bin/env bash
# Refresh selected repository-owned binary pins to their latest releases.
# With no package names, refresh OMP, code, and Codex. Prints one line per
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
    omp | code | codex | manifold) ;;
    *)
      refuse "$NARRATE_NAME" "$target is not a pin this repository owns"
      say "usage: ${0##*/} [omp|code|codex|manifold]..."
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

# Reports a bump this run declined to make. Cron reruns are unattended, so a
# hold must be visible where someone will actually see it: the job summary when
# running in Actions, stderr otherwise. It never lands on stdout, which is the
# bump manifest the workflow reads to decide whether to open a pull request.
hold() { # name reason
  refuse "$NARRATE_NAME" "holding $1 bump: $2"
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
  local tag="$1" version="$2" repo="$3" master_url health_url protocol_url hub candidate
  if ! master_url="$(jq -er .masterUrl "$repo_root/fleet/manifold.json")"; then
    hold manifold "fleet/manifold.json declares no masterUrl"
    return 1
  fi
  health_url="$master_url/healthz"
  show_command curl -fsSL --max-time 20 "$health_url"
  if ! hub="$(curl -fsSL --max-time 20 "$health_url" | jq -er .protocolVersion)"; then
    hold manifold "hub $master_url is unreachable, so $version cannot be cleared"
    return 1
  fi
  # Read the candidate's protocol version from its tagged source rather than by
  # running the asset: the number is a source constant, and a pin refresh must
  # never execute an unvetted binary to decide whether to pin it.
  protocol_url="https://raw.githubusercontent.com/$repo/$tag/packages/protocol/src/version.ts"
  show_command curl -fsSL --max-time 20 "$protocol_url"
  candidate="$(curl -fsSL --max-time 20 "$protocol_url" |
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
  if [[ "$version" == "$current" ]]; then
    say "$name is current at $current"
    return 0
  fi
  # A per-target precondition, declared as guard_<name>. Bumps without one are
  # unordered by construction and stay unconditional.
  if declare -F "guard_$name" >/dev/null && ! "guard_$name" "$tag" "$version" "$repo"; then
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
    manifold-agent-linux-x64 manifold-agent-darwin-arm64
fi
