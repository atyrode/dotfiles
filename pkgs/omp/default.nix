{
  fetchurl,
  lib,
  makeWrapper,
  stdenv,
}:

let
  version = "16.4.4";
  sources = {
    "x86_64-linux" = {
      asset = "omp-linux-x64";
      hash = "sha256-gQ2l2r5rLpQovmTtqhafJF+bT/kyrq4BiKcn6bcRr1U=";
    };
    "aarch64-linux" = {
      asset = "omp-linux-arm64";
      hash = "sha256-eW3zm8WDZ+EKpJ1FucIPsA28s0YdQLQ37GlBxFb3/AU=";
    };
    "x86_64-darwin" = {
      asset = "omp-darwin-x64";
      hash = "sha256-qyTZfzJJ7rv+l6s/GXaAWrFieWdUjnHmD5NopyfsCgg=";
    };
    "aarch64-darwin" = {
      asset = "omp-darwin-arm64";
      hash = "sha256-hubECoiYl+WhJ+QPAewU9yTfOa+JloeCOewQkSVBq2I=";
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
