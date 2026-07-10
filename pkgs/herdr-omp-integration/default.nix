{
  herdr,
  lib,
  runCommand,
}:

runCommand "herdr-omp-integration-${lib.getVersion herdr}" { } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME/.omp/agent/extensions"

  ${lib.getExe herdr} integration install omp

  source_file="$HOME/.omp/agent/extensions/herdr-omp-agent-state.ts"
  grep -q 'HERDR_INTEGRATION_ID=omp' "$source_file"
  grep -q 'HERDR_INTEGRATION_VERSION=' "$source_file"

  install -Dm444 "$source_file" "$out/share/omp/extensions/herdr-omp-agent-state.ts"
''
