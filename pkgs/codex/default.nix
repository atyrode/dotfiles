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
  version = "0.170.0";
  sources = {
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      hash = "sha256-fJ8h1cuuSGDRSzef3PcJ/zmc6HT9cUtYeD4bQZnCuak=";
    };
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      hash = "sha256-0FSRbM0opTggN2uNL3yHUYTKj0D81Eu6vrjuJAziR/U=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      hash = "sha256-DaawYfa1IjkBpac+hBvRRmWW4u9iDWiCM2D+vtL/frw=";
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
