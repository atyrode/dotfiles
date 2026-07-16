{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "code-tui";
  version = "0.1.0";
  # Verbatim source mirror of github.com/atyrode/code (the extracted repo),
  # kept here until the release-binary pin lands (update-pins, like pkgs/omp).
  # cli-kit is a normal published module dependency (github.com/atyrode/cli-kit),
  # so the old ../cli-kit fileset union + proxyVendor arrangement is gone: the
  # vendor FOD is plain vendoring and its hash moves on any go.mod/go.sum change.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "go") ./.)
      ./go.mod
      ./go.sum
    ];
  };
  vendorHash = "sha256-QB6M6jEriXK6VoR/BDfgSuAzlW4ZHeJ8now4TwFJbAc=";

  meta = {
    description = "Facet-dial launcher and routing-profile generator for oh-my-pi";
    homepage = "https://github.com/atyrode/code";
    license = lib.licenses.mit;
    mainProgram = "code";
  };
}
