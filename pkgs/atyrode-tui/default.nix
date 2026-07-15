{
  buildGoModule,
  lib,
}:

buildGoModule {
  pname = "atyrode-tui";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [
      ./.
      ../cli-kit
    ];
  };
  modRoot = "atyrode-tui";
  proxyVendor = true;
  vendorHash = "sha256-8Ay9Rav9W+kM84C4DUqCZuwUJJ70nphS3tG6gdoTv64=";

  meta = {
    description = "Interactive Bubble Tea cockpit for atyrode";
    mainProgram = "atyrode-tui";
    platforms = lib.platforms.all;
  };
}
