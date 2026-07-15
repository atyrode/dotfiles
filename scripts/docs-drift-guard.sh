#!/usr/bin/env bash
# Guard the docs-only CI fast path invariant (#169): a change confined to
# docs/** and README.md must not alter any Nix derivation other than the
# intentional whole-tree lints (docs-links, production-facts), which scan
# documentation on purpose and are built directly by the fast path. Any
# other drift means skipping the platform matrix would silently skip real
# verification, so the guard fails and ci-gate blocks the merge.
#
# The check is evaluation-only: it instantiates every flake check on every
# CI platform (drvPath, no builds) at the base and head revisions and
# compares the two maps. A derivation's drvPath hashes its entire source and
# dependency graph, so indirect dependencies (filesets, imports, deployed
# files) are covered by construction.
#
# Usage:
#   docs-drift-guard.sh <base-rev> <head-rev>            eval + compare
#   docs-drift-guard.sh --compare <base.json> <head.json>  compare only
#
# Snapshot JSON shape: { "<system>": { "<check>": "<drvPath>", ... }, ... }
set -euo pipefail

SYSTEMS=(x86_64-linux aarch64-linux aarch64-darwin)

usage() {
  sed -n 's/^# \{0,1\}//p' "$0" | sed -n '1,19p' >&2
  exit 2
}

# Print drifted "<system>.<check>" entries between two snapshot files,
# ignoring the intentional whole-tree lints (emitted on x86_64-linux only).
# Exits 0 with no output when clean.
drift_list() {
  jq -rn --slurpfile base "$1" --slurpfile head "$2" '
    def prune:
      del(.["x86_64-linux"]["docs-links"], .["x86_64-linux"]["production-facts"]);
    ($base[0] | prune) as $a
    | ($head[0] | prune) as $b
    | (($a | keys) + ($b | keys) | unique)[] as $sys
    | ((($a[$sys] // {}) | keys) + (($b[$sys] // {}) | keys) | unique)[] as $chk
    | select(($a[$sys][$chk]? // null) != ($b[$sys][$chk]? // null))
    | "\($sys).\($chk)"
  '
}

compare() {
  local drift
  drift="$(drift_list "$1" "$2")"
  if [ -n "$drift" ]; then
    echo "docs drift guard: documentation changes altered non-docs derivations:" >&2
    while IFS= read -r entry; do echo "  $entry" >&2; done <<< "$drift"
    echo "A docs/** or README.md path has become a derivation input; either" >&2
    echo "move it out of the inert set in .github/workflows/nix.yml (classify" >&2
    echo "job) or, for a new intentional whole-tree lint, add it to this" >&2
    echo "script's exclusions and build it in the docs fast path." >&2
    return 1
  fi
  echo "docs drift guard: no derivation drift outside the intentional whole-tree lints"
}

# Instantiate all checks for all CI systems at a revision. Uses a temporary
# ref so the nix git fetcher can resolve commits (e.g. a PR base fetched by
# sha) that no branch points at; shallow clones are supported.
snapshot() {
  local rev="$1" outfile="$2" repo sys first=1
  repo="$(git rev-parse --show-toplevel)"
  rev="$(git rev-parse "$rev^{commit}")"
  git update-ref "refs/drift-guard/$rev" "$rev"
  TEMP_REFS+=("refs/drift-guard/$rev")
  {
    printf '{'
    for sys in "${SYSTEMS[@]}"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '"%s":' "$sys"
      nix eval --json \
        "git+file://$repo?rev=$rev&shallow=1&allRefs=1#checks.$sys" \
        --apply 'checks: builtins.mapAttrs (_: drv: drv.drvPath) checks'
    done
    printf '}'
  } > "$outfile"
}

TEMP_REFS=()
WORKDIR=""
cleanup() {
  local ref
  for ref in "${TEMP_REFS[@]}"; do
    git update-ref -d "$ref" || true
  done
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}

case "${1:-}" in
--compare)
  [ $# -eq 3 ] || usage
  compare "$2" "$3"
  ;;
-h | --help | "")
  usage
  ;;
*)
  [ $# -eq 2 ] || usage
  trap cleanup EXIT
  WORKDIR="$(mktemp -d)"
  echo "docs drift guard: instantiating checks at base $1" >&2
  snapshot "$1" "$WORKDIR/base.json"
  echo "docs drift guard: instantiating checks at head $2" >&2
  snapshot "$2" "$WORKDIR/head.json"
  compare "$WORKDIR/base.json" "$WORKDIR/head.json"
  ;;
esac
