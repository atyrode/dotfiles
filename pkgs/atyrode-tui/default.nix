{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "atyrode-tui";
  version = "0.1.0";
  # cli-kit is a published module (github.com/atyrode/cli-kit) since its
  # extraction, so the source is just this directory and the vendor FOD is plain
  # vendoring: the hash moves on any go.mod/go.sum change (e.g. a cli-kit bump).
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "go") ./.)
      ./go.mod
      ./go.sum
    ];
  };
  subPackages = [
    "."
    "cmd/atyrode-preview-parser"
  ];
  vendorHash = "sha256-JpezTkfJ6J8W/8onXYK+oRl++JksH6+x67Sk+bcHd/U=";

  meta = {
    description = "Interactive Bubble Tea cockpit for atyrode";
    mainProgram = "atyrode-tui";
    platforms = lib.platforms.all;
  };
}
