{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "atyrode-preview";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "go") ./.)
      ./go.mod
      ./go.sum
    ];
  };
  subPackages = [ "cmd/atyrode-preview-parser" ];
  vendorHash = "sha256-bz6cvrUh8VtDru8zJAfkWdU/tUZsvfibqH+HTulKoxc=";

  meta = {
    description = "Converts an nh diff preview into the atyrode apply --preview-json document";
    mainProgram = "atyrode-preview-parser";
    platforms = lib.platforms.all;
  };
}
