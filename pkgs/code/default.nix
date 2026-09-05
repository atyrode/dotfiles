{
  fetchurl,
  lib,
  stdenvNoCC,
}:

# code (the oh-my-pi facet-dial launcher) lives in its own repository since the
# 2026-07 extraction; the dotfiles track its release binaries like omp/codex,
# bumped by ci/update-pins.sh. The archives carry static Go builds (CGO
# disabled), so no loader fixup is needed on any platform.
let
  version = "0.16.1";
  sources = {
    "x86_64-linux" = {
      asset = "code-linux-amd64";
      hash = "sha256-NX7unfK7jOpVQXt6k1HyssNzpY89ArHsCZZZ+r3EdgA=";
    };
    "aarch64-linux" = {
      asset = "code-linux-arm64";
      hash = "sha256-0LdW+4D55qi+u/vvS2uJLF/O17b+mlJWvic3BCVHihY=";
    };
    "x86_64-darwin" = {
      asset = "code-darwin-amd64";
      hash = "sha256-vsGmlAslW6/k4VjJNxapn+1Mx+wu18l1VOfjY18ZVpM=";
    };
    "aarch64-darwin" = {
      asset = "code-darwin-arm64";
      hash = "sha256-L3SmOTOBPqbeX4ucq+qb1u42NNY7Goa1Yg9DopJNGv0=";
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
