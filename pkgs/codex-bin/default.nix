{
  fetchurl,
  lib,
  stdenvNoCC,
}:

# nixpkgs builds codex from source against livekit-libwebrtc, which does not
# build on aarch64-darwin (linker failure upstream). Track the official
# release binary there, mirroring the ghostty-bin and omp repackages; drop
# this when livekit-libwebrtc builds on aarch64-darwin in nixpkgs again.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "codex";
  version = "0.142.5";

  src = fetchurl {
    url = "https://github.com/openai/codex/releases/download/rust-v${finalAttrs.version}/codex-aarch64-apple-darwin.tar.gz";
    hash = "sha256-cVaxmWJzXJz7VVzde6voxA55dogfhxK3gRmSGdLjpwc=";
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 codex-aarch64-apple-darwin "$out/bin/codex"
    runHook postInstall
  '';

  meta = {
    description = "OpenAI Codex CLI (official release binary)";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
