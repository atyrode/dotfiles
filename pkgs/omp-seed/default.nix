{
  coreutils,
  flock,
  jq,
  lib,
  writeShellApplication,
  yq-go,
}:

let
  seedConfig = ../omp-configured/config/plain-seed.yml;
  script = builtins.readFile ./omp-seed.sh;
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
  text = ''
    : "''${OMP_SEED_FILE:=${seedConfig}}"
    export OMP_SEED_FILE
    # The seeder's resolve dialogue asks the operator questions on a terminal
    # `atyrode apply` handed it, so it answers in the CLI's own voice.
    export ATYRODE_NARRATE=${../../pkgs/atyrode/lib/narrate.sh}
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
