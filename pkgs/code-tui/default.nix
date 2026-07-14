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
    fileset = lib.fileset.unions [
      ./.
      ../cli-kit
    ];
  };
  modRoot = "code-tui";
  # cli-kit is a local `replace` resolved from this build's src (above). With
  # plain vendoring `go mod vendor` would copy cli-kit INTO the vendor FOD, so
  # every cli-kit edit shifted this hash — and a warm cache could silently reuse
  # a stale FOD and mask the change. proxyVendor keeps only the remote module
  # cache in the FOD: the hash moves only when go.mod/go.sum change.
  proxyVendor = true;
  vendorHash = "sha256-8Ay9Rav9W+kM84C4DUqCZuwUJJ70nphS3tG6gdoTv64=";

  # The prompt→profile generator is invoked as `code`.
  postInstall = ''
    mv "$out/bin/code-tui" "$out/bin/code"
  '';

  meta = {
    description = "Bubble Tea prompt→profile generator for managed omp";
    mainProgram = "code";
  };
}
