{
  coreutils,
  gitMinimal,
  hostname,
  hostRegistry,
  jq,
  lib,
  makeWrapper,
  nh,
  runtimeShell,
  stdenvNoCC,
}:

let
  registry = builtins.toFile "atyrode-host-registry.json" (builtins.toJSON hostRegistry);
in
stdenvNoCC.mkDerivation {
  pname = "atyrode";
  version = "0.1.0";
  src = ./atyrode;
  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;
  installPhase = ''
    install -D -m755 "$src" "$out/bin/atyrode"
    substituteInPlace "$out/bin/atyrode" \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@registry@' '${registry}'
    wrapProgram "$out/bin/atyrode" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          gitMinimal
          hostname
          jq
          nh
        ]
      }
  '';

  meta = {
    description = "Safe operator and agent interface for atyrode dotfiles";
    license = lib.licenses.mit;
    mainProgram = "atyrode";
    platforms = lib.platforms.all;
  };
}
