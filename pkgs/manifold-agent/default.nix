# Fleet agent for the self-hosted manifold hub (#418), pinned as a compiled
# release asset like the other repository-owned binaries. The upstream flake
# output was the original pin, but its bun-deps fixed-output derivation is not
# reproducible across machines (atyrode/manifold#51): identical drvs produced
# different vendored trees on cold rebuilds, flapping every consumer gate.
# Release assets are built once by the upstream Release workflow after its
# full gate passes on the tagged source (atyrode/manifold#52).
{
  fetchurl,
  lib,
  makeWrapper,
  patchelf,
  stdenv,
}:

let
  version = "0.6.2";
  sources = {
    "x86_64-linux" = {
      asset = "manifold-agent-linux-x64";
      hash = "sha256-lVM5yIpIB+F3SwJ7vc6xh7upF7Q/6koKguqhvfDfbgk=";
    };
  };
  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported manifold-agent platform: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "manifold-agent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/atyrode/manifold/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = [
    makeWrapper
    patchelf
  ];

  installPhase = ''
    runHook preInstall

    # Like omp, a Bun single-file executable: patch PT_INTERP in place so the
    # binary runs as itself (--set-interpreter rewrites one page and leaves
    # the appended Bun payload intact). The wrapper bakes the pinned tag as
    # the default build provenance, mirroring the upstream flake wrapper, so
    # the agent's `starting` log line names what is deployed.
    install -Dm755 "$src" "$out/libexec/manifold-agent"
    patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$out/libexec/manifold-agent"
    makeWrapper "$out/libexec/manifold-agent" "$out/bin/manifold-agent" \
      --set-default MANIFOLD_BUILD "v${version}"

    runHook postInstall
  '';

  meta = {
    description = "manifold fleet agent: dial-out PTY daemon for the shared spatial workspace";
    homepage = "https://github.com/atyrode/manifold";
    license = lib.licenses.mit;
    mainProgram = "manifold-agent";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
