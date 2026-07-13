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
  vendorHash = "sha256-GEnl88M2KszTcv4mxjrLipR+Ne+16NdfhMK6+wJTIL0=";

  # The launcher picker is invoked as `code`.
  postInstall = ''
    mv "$out/bin/code-tui" "$out/bin/code"
  '';

  meta = {
    description = "Bubble Tea launcher picker for the managed omp profiles";
    mainProgram = "code";
  };
}
