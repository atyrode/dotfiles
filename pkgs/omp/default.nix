{
  fetchurl,
  lib,
  makeWrapper,
  stdenv,
}:

let
  version = "16.4.8";
  sources = {
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-zfB3XgW4jWP52mBt5ULMP8C+7fCoZLSsQvd3lh+GhEw=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-nOVX1ojLTTW6uiImJOt/RgFi4e8BDk5M8C8UIxLGacU=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-PocAgPRDgfbkhRA/+KgGds9GNUW0AN/HCdenS3q9yhs=";
    };
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-PaPT3RU6auZVyViRzQZtwAJE6cN+fJ8Yihl5FwRddEc=";
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

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    ${
      if stdenv.hostPlatform.isLinux then
        ''
          install -Dm755 "$src" "$out/libexec/omp"
          makeWrapper ${stdenv.cc.bintools.dynamicLinker} "$out/bin/omp" \
            --add-flags "$out/libexec/omp"
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
    homepage = "https://github.com/can1357/oh-my-pi";
    license = lib.licenses.mit;
    mainProgram = "omp";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
