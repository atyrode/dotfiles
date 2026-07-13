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
  # A plain build can reuse a cached FOD and hide the change; get the true value
  # from a fake-hash build (set to sha256-AAA…, read the reported `got:`) or CI.
  vendorHash = "sha256-/XKH5dXqQCWBHUEZjaDwlBFpdm8U0gEbnE+iTcURA9k=";

  # The launcher picker is invoked as `code`.
  postInstall = ''
    mv "$out/bin/code-tui" "$out/bin/code"
  '';

  meta = {
    description = "Bubble Tea launcher picker for the managed omp profiles";
    mainProgram = "code";
  };
}
