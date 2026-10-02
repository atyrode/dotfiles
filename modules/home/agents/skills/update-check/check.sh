#!/usr/bin/env bash
# Prints one line per available update of the fast-moving tools the operator
# relies on, or `updates: nothing to do`. Read-only: it asks GitHub through the
# authenticated `gh` and the public npm registry, and changes no pin, package
# or machine. Pins are read from each owner's default branch, not a checkout.
# Requires gh, jq and curl; any failed query fails the whole check.
set -euo pipefail

found=0
candidate() {
  printf '%s\n' "$*"
  found=1
}

raw() { # repo path
  gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/$2"
}

# The same version line ci/update-pins.sh rewrites.
pinned=""
bump() { # name file release_repo tag_prefix [note]
  local tag
  pinned="$(raw atyrode/dotfiles "$2" | sed -nE 's/^[[:space:]]*version = "([^"]+)";$/\1/p' | head -n 1)"
  tag="$(gh api "repos/$3/releases/latest" --jq .tag_name)"
  if [ "$pinned" != "${tag#"$4"}" ]; then
    candidate "$1 $pinned -> ${tag#"$4"}: atyrode/dotfiles $2${5:+ ($5)}"
  fi
}

# A machine behind the published pin needs activation, not another bump.
here() { # name version_on_this_machine
  if [ -n "$2" ] && [ "$2" != "$pinned" ]; then
    candidate "$1 $2 on this machine, dotfiles main pins $pinned: activation"
  fi
}

bump omp pkgs/omp/default.nix can1357/oh-my-pi v
if command -v omp >/dev/null; then
  here omp "$(omp --version | sed -nE 's#^omp/##p')"
fi

bump codex pkgs/codex/default.nix openai/codex rust-v
if command -v codex >/dev/null; then
  here codex "$(codex --version | sed -nE 's/^codex-cli //p')"
fi

bump manifold-agent pkgs/manifold-agent/default.nix atyrode/manifold v \
  "hub first, docs/manifold.md#upgrades"

# The OMP plugin family builds against the published @oh-my-pi/* SDK packages,
# which upstream releases together with OMP itself.
sdk="$(raw atyrode/manifold-omp plugins/package.json |
  jq -r '[.dependencies | to_entries[] | select(.key | startswith("@oh-my-pi/")) | .value] | unique | join(",")')"
npm="$(curl -fsSL https://registry.npmjs.org/@oh-my-pi/pi-ai/latest | jq -r .version)"
if [ "$sdk" != "$npm" ]; then
  candidate "omp sdk $sdk -> $npm: atyrode/manifold-omp plugins/package.json"
fi

# An open bot bump is already proposed; its merge state says what it waits on.
pending="$(gh pr list -R atyrode/dotfiles --head bot/update-pins --state open \
  --json url,createdAt,mergeStateStatus \
  --jq '.[] | "pending \(.url) open since \(.createdAt[:10]), merge state \(.mergeStateStatus)"')"
if [ -n "$pending" ]; then
  candidate "$pending"
fi

if [ "$found" -eq 0 ]; then
  echo "updates: nothing to do"
fi
