{
  fetchurl,
  lib,
  stdenvNoCC,
}:

# Codex is repository-owned: upstream releases outpace nixpkgs (which also
# fails to build codex on aarch64-darwin against livekit-libwebrtc), so every
# platform tracks the official release binaries, mirroring the omp repackage.
# The Linux assets are static musl builds and need no loader fixup.
let
  version = "0.153.3";
  sources = {
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      hash = "sha256-As3L2HTBYW8sq29gJYAyneGwCya/IW04SzSFGamzVs0=";
    };
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      hash = "sha256-b/lnS7AOFHNMJ0i8h4jqs8tuWsU+vefh54C07Xr0jLo=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      hash = "sha256-aP9+sik33k9rRKMNZrqJPa8oDSE0dAj/vyUBooE2vxk=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "Unsupported codex platform: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${version}/${source.asset}.tar.gz";
    inherit (source) hash;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 ${source.asset} "$out/bin/codex"
    runHook postInstall
  '';

  meta = {
    description = "OpenAI Codex CLI (official release binary)";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
