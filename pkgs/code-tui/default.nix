{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "code-tui";
  version = "0.1.0";
  # code-tui builds on the shared cli-kit (../cli-kit, via a local replace), so
  # the source must carry both module dirs; modRoot points the build at code-tui.
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [ ./. ../cli-kit ];
  };
  modRoot = "code-tui";
  # cli-kit is a local `replace` whose source lives in this build's src (above),
  # so any change to pkgs/cli-kit/*.go shifts this hash — bump it on cli-kit edits.
  vendorHash = "sha256-Kw9KeayOAbWlOQxVszD5W/qzaI0qbF6L+h4zVjONbOg=";

  # The launcher picker is invoked as `code`.
  postInstall = ''
    mv "$out/bin/code-tui" "$out/bin/code"
  '';

  meta = {
    description = "Bubble Tea launcher picker for the managed omp profiles";
    mainProgram = "code";
  };
}
