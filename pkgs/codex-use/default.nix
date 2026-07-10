{
  codex-configured,
  coreutils,
  findutils,
  lib,
  makeWrapper,
  managedAgents ? ../../codex/AGENTS.md,
  managedConfig ? ../../codex/config.toml,
  procps,
  runtimeShell,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "codex-use";
  version = "1.0.0";
  src = ./codex-use;
  nativeBuildInputs = [ makeWrapper ];
  dontUnpack = true;

  installPhase = ''
    install -D -m755 "$src" "$out/bin/codex-use"
    install -D -m644 ${./_codex-use} "$out/share/zsh/site-functions/_codex-use"
    substituteInPlace "$out/bin/codex-use" \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@agents@' '${managedAgents}' \
      --replace-fail '@config@' '${managedConfig}' \
      --replace-fail '@codex@' '${lib.getExe codex-configured}'
    wrapProgram "$out/bin/codex-use" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          findutils
          procps
        ]
      }
  '';

  meta = {
    description = "Transactional Codex authentication-profile manager";
    license = lib.licenses.mit;
    mainProgram = "codex-use";
    platforms = lib.platforms.all;
  };
}
