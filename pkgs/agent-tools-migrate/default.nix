{
  coreutils,
  diffutils,
  flock,
  jq,
  lib,
  writeShellApplication,
  yq-go,
}:

writeShellApplication {
  name = "atyrode-agent-tools-migrate";

  runtimeInputs = [
    coreutils
    diffutils
    flock
    jq
    yq-go
  ];

  text = lib.removePrefix "#!/usr/bin/env bash\n" (
    builtins.readFile ../../scripts/agent-tools-migrate.sh
  );

  meta.description = "Guarded migration for legacy atyrode OMP and Herdr state";
}
