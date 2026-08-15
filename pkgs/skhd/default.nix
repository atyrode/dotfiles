{
  bash,
  fetchFromGitHub,
  gitMinimal,
  lib,
  stdenv,
  zig,
}:

let
  version = "0.2.0";
  revision = "7e95d99";
  zbench = fetchFromGitHub {
    owner = "hendriknielaender";
    repo = "zbench";
    tag = "v0.13.0";
    hash = "sha256-u/N1KkCeu4AgK4ZaR8PTgla1oDV5PsipiW48sImetW4=";
  };
in
stdenv.mkDerivation {
  pname = "skhd";
  inherit version;

  src = fetchFromGitHub {
    owner = "jackielii";
    repo = "skhd.zig";
    tag = "v${version}";
    hash = "sha256-Qi5srrpdhf3VcXaqZbijJD23Um0G7WgRzK0hR+mb7nU=";
  };

  nativeBuildInputs = [
    bash
    gitMinimal
    zig
  ];

  postPatch = ''
    # Zig 0.16 requires build.zig.zon paths to be relative to the package root.
    # Copy the separately hash-pinned dependency into the ephemeral build tree;
    # no network fetch or mutable global package cache is involved.
    mkdir -p .vendor
    cp -R ${zbench} .vendor/zbench
    chmod -R u+w .vendor/zbench
    substituteInPlace build.zig.zon \
      --replace-fail '.url = "https://github.com/hendriknielaender/zbench/archive/refs/tags/v0.13.0.tar.gz",' '.path = ".vendor/zbench",' \
      --replace-fail '.hash = "zbench-0.13.0-YTdc7xVBAQCCMC-IdLLuotBeiNNNm8k9Pi2V4VYqrwfI",' ""

    # fetchFromGitHub intentionally strips .git. Keep the version identity
    # deterministic rather than allowing the build script to report
    # "dev-unknown" for an audited release tag.
    substituteInPlace build.zig \
      --replace-fail 'GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo '\'''unknown'\''')' 'GIT_HASH=${revision}' \
      --replace-fail 'if git describe --exact-match --tags HEAD >/dev/null 2>&1; then' 'if true; then'

    # This workstation never delegates TCC-protected microphone access through
    # a hotkey command. Do not advertise or invite a permission the managed
    # configuration cannot use.
    substituteInPlace assets/Info.plist.template \
      --replace-fail '    <key>NSMicrophoneUsageDescription</key>' "" \
      --replace-fail '    <string>Allow skhd to launch hotkeys that record audio, such as voice transcription commands.</string>' ""
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    zig build app -Doptimize=ReleaseFast --prefix "$out"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    test -x "$out/skhd.app/Contents/MacOS/skhd"
    mkdir -p "$out/Applications"
    mv "$out/skhd.app" "$out/Applications/skhd.app"
    rm -f "$out/Applications/skhd.app/Contents/MacOS/skhd-grabber"
    test ! -e "$out/Applications/skhd.app/Contents/MacOS/skhd-grabber"
    # The optional root grabber is deliberately not shipped. Caps Lock is a
    # one-key Apple hidutil mapping and ordinary hotkeys remain user-session
    # only; enabling the grabber requires a new package and policy review.
    rm -rf "$out/bin"
    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "Pinned user-session skhd hotkey daemon app";
    homepage = "https://github.com/jackielii/skhd.zig";
    license = lib.licenses.mit;
    mainProgram = "skhd";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
