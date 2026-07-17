{
  fetchurl,
  lib,
  stdenvNoCC,
}:

# code (the oh-my-pi facet-dial launcher) lives in its own repository since the
# 2026-07 extraction; the dotfiles track its release binaries like omp/codex,
# bumped by scripts/update-pins.sh. The archives carry static Go builds (CGO
# disabled), so no loader fixup is needed on any platform.
let
  version = "0.3.0";
  sources = {
    "x86_64-linux" = {
      asset = "code-linux-amd64";
      hash = "sha256-SQ9SqqjZtdonhWp6JJyctgs/BnTiAaY5Zl7Ti5bzluI=";
    };
    "aarch64-linux" = {
      asset = "code-linux-arm64";
      hash = "sha256-qwsbpO5SEVFkQ9rVw6jI3XlDzo2Jo6TyWbv5yM0QSxU=";
    };
    "x86_64-darwin" = {
      asset = "code-darwin-amd64";
      hash = "sha256-dsFsiSTc6COdjysxZD3aqAypVUMDJyVASpzlya1UyEQ=";
    };
    "aarch64-darwin" = {
      asset = "code-darwin-arm64";
      hash = "sha256-uh1ntylvWnUUbYqcvaHK6Qs8TGrTV/E4lSfNW8sToWc=";
    };
  };
  source =
    sources.${stdenvNoCC.hostPlatform.system}
      or (throw "Unsupported code platform: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "code";
  inherit version;

  src = fetchurl {
    url = "https://github.com/atyrode/code/releases/download/v${version}/${source.asset}.tar.gz";
    inherit (source) hash;
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 code "$out/bin/code"
    runHook postInstall
  '';

  meta = {
    description = "Facet-dial launcher and routing-profile generator for oh-my-pi";
    homepage = "https://github.com/atyrode/code";
    license = lib.licenses.mit;
    mainProgram = "code";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
