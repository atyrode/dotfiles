{ lib, pkgs }:

let
  # Every .nix source in the tree (fileFilter keeps only .nix, so edits to other
  # files don't invalidate the check and new .nix files are covered automatically).
  nixSources = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ../.;
  };
in
pkgs.runCommand "check-nixfmt"
  {
    nativeBuildInputs = [ pkgs.nixfmt ];
  }
  ''
    cd ${nixSources}
    if ! find . -name '*.nix' -exec nixfmt --check {} +; then
      echo 'These Nix files are not nixfmt-clean (see above). Run `nix fmt` to fix them.' >&2
      exit 1
    fi
    mkdir "$out"
  ''
