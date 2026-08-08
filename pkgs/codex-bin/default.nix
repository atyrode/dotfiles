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
  version = "0.146.0";
  sources = {
    "aarch64-darwin" = {
      asset = "codex-aarch64-apple-darwin";
      hash = "sha256-J1ATLTAOZPHb/7lePZE/2cnceBK8jhvOXGE1cki3kp4=";
    };
    "x86_64-linux" = {
      asset = "codex-x86_64-unknown-linux-musl";
      hash = "sha256-W6O5QFVDlTCB9mHQhU0mb3biq75R1BNJNVo23nZzd2o=";
    };
    "aarch64-linux" = {
      asset = "codex-aarch64-unknown-linux-musl";
      hash = "sha256-l1uskVYqvu3rj3ljbVGoZkmzHzSp3mo7ywWVZbbPH4c=";
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
