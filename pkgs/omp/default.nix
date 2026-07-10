{
  fetchurl,
  lib,
  makeWrapper,
  stdenv,
}:

let
  version = "16.3.14";
  sources = {
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-i3zj/IJJS1uB9DlFTbAzvHnaipTnUUEYLrr+Ed2zlZk=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-zoBJyPF6Sho25Ax2bxzqi2H5EeSKfP1v9eiwW5i/eIA=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-jUalGmV60WPWUZyCRxTE2O8FBqzWOsQv8MGq9vhswC4=";
    };
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-O9ZXURhA1jF6BE1qm/j5AzjjjrIMh8stDkvUq4IuPXQ=";
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
