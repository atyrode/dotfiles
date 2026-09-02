{
  coreutils,
  flock,
  lib,
  writeShellApplication,
}:

let
  seedConfig = ../../modules/home/codex/config.toml;
  script = builtins.readFile ./codex-seed.sh;
in
(writeShellApplication {
  name = "atyrode-codex-seed";
  runtimeInputs = [
    coreutils
    flock
  ];
  # The seed ships from the Nix store but stays overridable so the check can
  # exercise it against a fixture file.
  text = ''
    export ATYRODE_NARRATE=${../../pkgs/atyrode/lib/narrate.sh}
    : "''${CODEX_SEED_FILE:=${seedConfig}}"
    export CODEX_SEED_FILE
  ''
  + lib.removePrefix "#!/usr/bin/env bash\nset -euo pipefail\n" script;
  meta = {
    description = "One-time seed of curated Codex defaults into ~/.codex/config.toml";
    license = lib.licenses.mit;
    mainProgram = "atyrode-codex-seed";
  };
}).overrideAttrs
  (previous: {
    passthru = (previous.passthru or { }) // {
      inherit seedConfig;
    };
  })
