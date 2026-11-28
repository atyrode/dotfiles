#!/usr/bin/env bash
# Read NUL-delimited repository-relative paths from stdin and write GitHub
# Actions outputs. An empty or unterminated listing keeps full verification.
set -euo pipefail

code=false
darwin=false
saw_path=false

while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue
  saw_path=true

  case "$path" in
    # Documentation-only changes are guarded by docs-drift-guard.sh before the
    # full matrix is skipped.
    README.md | docs/*)
      ;;

    # This module contributes configuration only when pkgs.stdenv.hostPlatform.isLinux.
    # The Linux CI legs still evaluate it; native Darwin has no affected
    # configuration to verify.
    modules/home/desktop/linux.nix)
      code=true
      ;;

    # Imported only by the ci-01 NixOS constructor in lib/configurations.nix.
    # Other NixOS files, including the constructor, are not allowlisted here.
    modules/nixos/myparcelle-ci-ci-01.nix)
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

if ! "$saw_path" || [ -n "$path" ]; then
  code=true
  darwin=true
fi

printf 'code=%s\ndarwin=%s\n' "$code" "$darwin"
