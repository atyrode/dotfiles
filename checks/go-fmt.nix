{ lib, pkgs }:

let
  # buildGoModule does not gofmt-check, so drift in the Go packages (atyrode-tui
  # today) builds green. Scope this guard to the .go sources alone so edits to
  # default.nix / go.mod don't invalidate it, and so it grows to cover any future
  # Go package under pkgs/ automatically.
  goSources = lib.fileset.toSource {
    root = ../pkgs;
    fileset = lib.fileset.fileFilter (file: file.hasExt "go") ../pkgs;
  };
in
pkgs.runCommand "check-go-fmt"
  {
    nativeBuildInputs = [ pkgs.go ];
  }
  ''
    unformatted="$(cd ${goSources} && gofmt -l .)"
    if [ -n "$unformatted" ]; then
      echo 'These Go files are not gofmt-clean:' >&2
      echo "$unformatted" >&2
      echo 'Run `gofmt -w pkgs` to fix them.' >&2
      exit 1
    fi
    mkdir "$out"
  ''
