{
  fetchurl,
  lib,
  patchelf,
  stdenv,
}:

let
  version = "17.0.2";
  sources = {
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-ZZUsz4eI8plWICA4cVJVNFMO5RFlRwL4IH+ivSOL10M=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-M/oCaA4NA+fpHyjjItSaARyTjJPzh0WMpLutC+DSge0=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-2rA4WXvfaPuqdWyP4as4egZIEKWQl7AMY8oCRR5kRew=";
    };
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-vQ+oTzby3FLgqrkfLYieU3g4kpo9Sah5ZGGjS3+dlmw=";
    };
  };
  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported OMP platform: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "omp";
  inherit version;

  src = fetchurl {
    url = "https://github.com/can1357/oh-my-pi/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ patchelf ];

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/bin/omp"

    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      # omp is a Bun single-file executable that re-execs itself
      # (process.execPath) to spawn its subprocess workers
      # (__omp_worker_stt & co). Launching it through an ld.so wrapper
      # turns execPath into the loader, so every worker spawn dies with
      # code 127. --set-interpreter rewrites PT_INTERP in place and keeps
      # the appended Bun payload intact; --set-rpath would relocate
      # sections and corrupt it (and is unnecessary: the binary needs
      # nothing beyond glibc, which the pinned loader resolves from its
      # own store path).
      patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$out/bin/omp"
    ''}

    runHook postInstall
  '';

  postFixup = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out/share/zsh/site-functions"
    "$out/bin/omp" completions zsh > "$out/share/zsh/site-functions/_omp"
  '';

  meta = {
    description = "AI coding agent for the terminal";
    homepage = "https://github.com/can1357/oh-my-pi";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
