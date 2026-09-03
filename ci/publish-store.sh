#!/usr/bin/env bash
# Publish everything this runner built to the fleet cache.
#
# A binary cache that holds only the finished closures answers the question
# "what does a machine download at activation" and no other. The expensive
# question in a day's work is different: a pull request that changes one file
# rebuilt every check derivation on three platforms, because nothing that CI
# compiled on the way to a green main was ever kept. This publishes the
# intermediate work too, so the next run downloads what it did not change.
#
# What is ours is exactly what carries no upstream signature: a path signed by
# cache.nixos.org came from there and pushing it back would be a copy for
# nobody, and a path already signed by the fleet key is already here. Sources
# and derivations are skipped: they are cheap to re-instantiate and would
# double the object count for no build time saved.
set -Eeuo pipefail

: "${AWS_ACCESS_KEY_ID:?the cache credentials must be in the environment}"
: "${AWS_SECRET_ACCESS_KEY:?the cache credentials must be in the environment}"
: "${NIX_CACHE_SIGNING_KEY:?the signing key must be in the environment}"

endpoint="s3://atyrode-nix-cache?endpoint=cellar-c2.services.clever-cloud.com&region=us-east-1&scheme=https&compression=zstd&parallel-compression=true"

key="$(mktemp)"
trap 'rm -f "$key"' EXIT
(umask 077 && printf '%s\n' "$NIX_CACHE_SIGNING_KEY" >"$key")

mapfile -t paths < <(
  nix path-info --all --json |
    jq -r '
      (if type == "object" then to_entries | map(.value + {path: .key}) else . end)
      | .[]
      | select((.signatures // []) | any(startswith("cache.nixos.org-1:") or startswith("atyrode-cache-1:")) | not)
      | select((.path | endswith(".drv")) | not)
      | select(.deriver != null)
      | .path
    '
)

if [[ "${#paths[@]}" -eq 0 ]]; then
  echo "nothing built here that the cache does not already have"
  exit 0
fi

echo "publishing ${#paths[@]} locally built paths"
nix copy --to "$endpoint&secret-key=$key" "${paths[@]}"
