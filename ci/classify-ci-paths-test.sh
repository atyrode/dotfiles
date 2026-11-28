#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
classifier="${CLASSIFIER:-$repo_root/ci/classify-ci-paths.sh}"

assert_classification() {
  local expected actual
  expected="$1"
  shift
  actual="$(printf '%s\n' "$@" | bash "$classifier")"
  if [ "$actual" != "$expected" ]; then
    printf 'classification mismatch for: %s\nexpected:\n%s\nactual:\n%s\n' "$*" "$expected" "$actual" >&2
    return 1
  fi
}

assert_classification $'code=false\ndarwin=false' README.md docs/guide.md
assert_classification $'code=true\ndarwin=true' modules/darwin/default.nix
assert_classification $'code=true\ndarwin=true' flake.nix flake.lock
assert_classification $'code=true\ndarwin=true' modules/shared/capability-contract.nix
assert_classification $'code=true\ndarwin=true' pkgs/atyrode-preview/preview/parser.go
assert_classification $'code=true\ndarwin=true' checks/lints/docs-links.nix
assert_classification $'code=true\ndarwin=true' fleet/hosts.tsv
assert_classification $'code=true\ndarwin=true' .github/workflows/nix.yml
assert_classification $'code=true\ndarwin=false' modules/home/desktop/linux.nix
assert_classification $'code=true\ndarwin=false' modules/home/desktop/linux.nix docs/guide.md
assert_classification $'code=true\ndarwin=true' modules/home/desktop/linux.nix unknown/new-file
assert_classification $'code=true\ndarwin=false' modules/nixos/myparcelle-ci-ci-01.nix
assert_classification $'code=true\ndarwin=false' modules/nixos/myparcelle-ci-ci-01.nix docs/hosts.md
assert_classification $'code=true\ndarwin=true' lib/configurations.nix modules/nixos/myparcelle-ci-ci-01.nix
assert_classification $'code=true\ndarwin=true' modules/nixos/myparcelle-ci-ci-01.nix modules/nixos/unknown.nix
assert_classification $'code=true\ndarwin=true' modules/nixos/myparcelle-ci-ci-01.nix .github/workflows/nix.yml
assert_classification $'code=true\ndarwin=true' ci/classify-ci-paths.sh modules/nixos/myparcelle-ci-ci-01.nix
assert_classification $'code=true\ndarwin=true' modules/nixos/myparcelle-ci-ci-01.nix ci/classify-ci-paths-test.sh
assert_classification $'code=true\ndarwin=true' modules/nixos/myparcelle-ci-ci-01.nix modules/shared/previous-name.nix
assert_classification $'code=true\ndarwin=true' unknown/new-file

empty_output="$(printf '' | bash "$classifier")"
if [ "$empty_output" != $'code=true\ndarwin=true' ]; then
  printf 'empty input must fail safe; got:\n%s\n' "$empty_output" >&2
  exit 1
fi
