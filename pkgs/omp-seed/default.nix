{
  coreutils,
  flock,
  jq,
  lib,
  writeShellApplication,
  yq-go,
}:

let
  seedConfig = ../../omp/plain-seed.yml;
  script = builtins.readFile ../../scripts/omp-seed.sh;
in
(writeShellApplication {
  name = "atyrode-omp-seed";
  runtimeInputs = [
    coreutils
    flock
    jq
    yq-go
  ];
  # The seed ships from the Nix store but stays overridable so checks can
  # exercise seed updates against a fixture file.
  text =
    ''
      : "''${OMP_SEED_FILE:=${seedConfig}}"
      export OMP_SEED_FILE
    ''
    + lib.removePrefix "#!/usr/bin/env bash\nset -euo pipefail\n" script;
  meta = {
    description = "Drift-aware seeding of curated plain-omp defaults";
    license = lib.licenses.mit;
    mainProgram = "atyrode-omp-seed";
  };
}).overrideAttrs
  (previous: {
    passthru = (previous.passthru or { }) // {
      inherit seedConfig;
    };
  })
