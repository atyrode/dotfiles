{ lib, pkgs }:

let
  # The whole tree, so links from Markdown to non-Markdown authority files (for
  # example fleet/annotations.nix) can be resolved and verified.
  src = lib.fileset.toSource {
    root = ../../.;
    fileset = ../../.;
  };
in
pkgs.runCommand "check-docs-links"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./docs-links-test.py} ${./docs-links.py}
    python3 ${./docs-links.py} ${src}
    mkdir "$out"
  ''
