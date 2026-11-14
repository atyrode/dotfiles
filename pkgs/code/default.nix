{
  buildGoModule,
  fetchFromGitHub,
  lib,
  omp,
}:

# Temporary standalone continuity bridge, not the native Manifold Code product.
# Keep the public v0.19.0 source fixed; reviewed routing/metadata changes live in
# the auditable downstream patch rather than an unmerged or moving source pin.
buildGoModule {
  pname = "code";
  version = "0.19.0";

  src = fetchFromGitHub {
    owner = "atyrode";
    repo = "code";
    # Public v0.19.0; never advance this bridge through routine pin automation.
    rev = "23f89adec1ff4b3b85018d4c77a38b79de227bad";
    hash = "sha256-rHy7EP7COGP2oL3nzgumJ2FzAxNc6eqAX/OIdUw3yhk=";
  };

  patches = [ ./native-shared-roles.patch ];
  vendorHash = "sha256-WcdZL74OHaccfNA9aI/SgkMmj3yfV7bkA0ELa02enMI=";
  subPackages = [ "." ];
  # Raw OMP is independent of the configured launcher. The native smoke uses a
  # disposable HOME with auth cleared: schema/role metadata only, never probes.
  nativeCheckInputs = [ omp ];
  env = {
    CGO_ENABLED = "0";
    CODE_OMP = lib.getExe omp;
    CODE_OMP_SMOKE = "1";
  };
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Facet-dial launcher and routing-profile generator for oh-my-pi";
    homepage = "https://github.com/atyrode/code";
    license = lib.licenses.mit;
    mainProgram = "code";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
