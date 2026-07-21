{
  fetchurl,
  lib,
  makeWrapper,
  patchelf,
  stdenv,
}:

let
  version = "17.0.6-atyrode.1";
  sources = {
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-NASJMAsKhGsRvljHMuRicURE5S5tg8KX/h8sIzXnAAw=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-xKj46OTI9zAxU4AKb4HnLkuuhqqCVCJQFjN/pJ6eEwg=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-lNXlnkFDbOUCahBsjoSpO/8TWNLHGvOodkFOkXlnN3M=";
    };
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-SeEzTxt/jVR63+Ep6ICqj0TfuvK3ix1W0rlHfwZzRYE=";
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
    url = "https://github.com/atyrode/omp/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    makeWrapper
    patchelf
  ];

  installPhase = ''
    runHook preInstall

    ${
      if stdenv.hostPlatform.isLinux then
        ''
          # omp is a Bun single-file executable. It re-execs itself
          # (process.execPath) to spawn its subprocess workers
          # (__omp_worker_stt & co), so it must run as the binary itself,
          # not via an `ld.so <binary>` wrapper: that makes process.execPath
          # the loader and every worker dies with `error while loading
          # shared libraries: __omp_worker_*` (exit 127). Patch PT_INTERP in
          # place instead -- --set-interpreter rewrites one page and leaves
          # the appended Bun payload intact (--set-rpath relocates sections
          # and segfaults it).
          install -Dm755 "$src" "$out/libexec/omp"
          patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} "$out/libexec/omp"

          # The speech workers dlopen a downloaded manylinux prebuilt
          # (sherpa-onnx.node) that needs libstdc++/libgcc_s; under the pinned
          # loader those are not on the default search path. Expose them via
          # the wrapper -- the re-exec'd workers inherit the env, and execPath
          # stays correct because the wrapper execs the patched binary itself.
          makeWrapper "$out/libexec/omp" "$out/bin/omp" \
            --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}
        ''
      else
        ''
          install -Dm755 "$src" "$out/bin/omp"
        ''
    }

    runHook postInstall
  '';

  postFixup = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out/share/zsh/site-functions"
    "$out/bin/omp" completions zsh > "$out/share/zsh/site-functions/_omp"
  '';

  meta = {
    description = "AI coding agent for the terminal";
    homepage = "https://github.com/atyrode/omp";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
