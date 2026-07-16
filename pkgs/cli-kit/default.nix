{
  buildGoModule,
  lib,
}:

# cli-kit is a library module (no executables) consumed by the custom CLIs via a
# local `replace`. It is packaged here only so the flake can expose it under
# checks.<system>.cli-kit, whose build runs the unit tests (buildGoModule's
# checkPhase) — the build installs nothing.
buildGoModule {
  pname = "cli-kit";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      (lib.fileset.fileFilter (f: f.hasExt "go") ./.)
    ];
  };

  vendorHash = "sha256-88URr9JQsZvwEZ4F4R5R+2z9Xy26yjx7Js38KoCDhYA=";

  doCheck = true;

  meta = {
    description = "Shared visual layer + Bubble Tea components for the dotfiles' custom CLIs";
    license = lib.licenses.mit;
  };
}
