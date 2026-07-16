#!/usr/bin/env bash
# Classify pull-request paths for CI. Read one repository-relative path per line
# from stdin and write GitHub Actions outputs to stdout. An empty input is
# deliberately fail-safe: callers must not skip verification when file listing
# fails or is incomplete.
set -euo pipefail

code=false
darwin=false
saw_path=false

while IFS= read -r path; do
  [ -n "$path" ] || continue
  saw_path=true

  case "$path" in
    # These documentation paths are guarded by docs-drift-guard.sh before the
    # full matrix is skipped. docs/omp is versioned runtime documentation and
    # remains a full-matrix input.
    README.md | docs/*)
      case "$path" in
        docs/omp/*)
          code=true
          darwin=true
          ;;
      esac
      ;;

    # This module contributes configuration only when pkgs.stdenv.isLinux.
    # The Linux CI legs still evaluate it; native Darwin has no affected
    # configuration to verify.
    home/linux-desktop.nix)
      code=true
      ;;

    # Every other path is shared, Darwin-specific, or not yet proven inert.
    # New paths must opt in here only after establishing their platform scope.
    *)
      code=true
      darwin=true
      ;;
  esac
done

if ! "$saw_path"; then
  code=true
  darwin=true
fi

printf 'code=%s\ndarwin=%s\n' "$code" "$darwin"
