{
  herdr,
  lib,
  runCommand,
  writeShellApplication,
}:

let
  wrapper = writeShellApplication {
    name = "herdr";
    text = ''
      for arg in "$@"; do
        if [[ "$arg" == -- ]]; then
          break
        fi
        if [[ "$arg" == update ]]; then
          printf '%s\n' 'Herdr is managed by Nix. Update the flake input, then run zconf.' >&2
          exit 2
        fi
      done

      exec ${lib.escapeShellArg (lib.getExe herdr)} "$@"
    '';
  };
in
runCommand "herdr-configured-${lib.getVersion herdr}"
  {
    pname = "herdr-configured";
    version = lib.getVersion herdr;

    passthru.rawHerdr = herdr;

    meta = herdr.meta // {
      description = "Nix-managed Herdr with self-updates disabled";
      mainProgram = "herdr";
    };
  }
  ''
    mkdir -p "$out/bin"
    ln -s ${lib.getExe wrapper} "$out/bin/herdr"
  ''
