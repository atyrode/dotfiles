{
  lib,
  sketchybar,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "macos-automation-bridge";
  version = "1.0.0";
  src = ./.;

  postPatch = ''
    substituteInPlace main.m --replace-fail '@sketchybar@' '${lib.getExe sketchybar}'
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -fobjc-arc -Os -Wall -Wextra -Werror \
      -framework Cocoa \
      -framework CoreWLAN \
      -framework IOKit \
      main.m -o atyrode-automation-bridge
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app="$out/Applications/atyrode-automation-bridge.app"
    mkdir -p "$app/Contents/MacOS"
    install -m755 atyrode-automation-bridge "$app/Contents/MacOS/atyrode-automation-bridge"
    install -m644 Info.plist "$app/Contents/Info.plist"
    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "Narrow event bridge for the managed macOS desktop";
    license = lib.licenses.mit;
    mainProgram = "atyrode-automation-bridge";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
