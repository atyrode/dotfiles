{
  appimageTools,
  fetchurl,
  lib,
  stdenv,
  stdenvNoCC,
  undmg,
}:

# Orca is repository-owned because nixpkgs' `orca` is the GNOME screen reader,
# not stablyai/orca. Package the official release artifacts unchanged. Linux
# exposes the AppImage CLI; macOS leaves CLI registration to the signed app.
let
  pname = "orca-ide";
  version = "1.4.148";
  sources = {
    "x86_64-linux" = {
      asset = "orca-linux.AppImage";
      hash = "sha256-jELQCfwtwUuO73Uw4Lks3dZuTGRYzMMRtMz1qLDVsO8=";
    };
    "aarch64-linux" = {
      asset = "orca-linux-arm64.AppImage";
      hash = "sha256-xvFoJQLOy+UeW79ZsqYoHrg9gF1CREJoq+3Z8WvR3Sw=";
    };
    "x86_64-darwin" = {
      asset = "orca-macos-x64.dmg";
      hash = "sha256-OmdSjvKzHVUSUR+lr7ILBcZ4cyinB82WIBhxzB+VbG8=";
    };
    "aarch64-darwin" = {
      asset = "orca-macos-arm64.dmg";
      hash = "sha256-IFWEx4CC5bbU6mhw41P+Oqx+DuOFn5FNveGVr7G85us=";
    };
  };
  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported Orca platform: ${stdenv.hostPlatform.system}");
  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };
  meta = {
    description = "Worktree IDE for AI coding agents (official release binary)";
    homepage = "https://github.com/stablyai/orca";
    changelog = "https://github.com/stablyai/orca/releases/tag/v${version}";
    license = lib.licenses.mit;
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
in
if stdenv.hostPlatform.isLinux then
  let
    contents = appimageTools.extractType2 {
      inherit pname src version;
    };
  in
  appimageTools.wrapType2 {
    inherit pname src version;

    # `orca serve` starts Xvfb when DISPLAY is unset, and Git inside Orca's FHS
    # runtime shells out to OpenSSH for SSH remotes. Carry both dependencies so
    # a manually started VPS trial needs no host package or service setup.
    extraPkgs = pkgs: [
      pkgs.openssh
      pkgs.xorg-server
    ];

    extraInstallCommands = ''
      ln -s "$out/bin/${pname}" "$out/bin/orca"

      install -Dm444 ${contents}/orca-ide.desktop "$out/share/applications/orca-ide.desktop"
      substituteInPlace "$out/share/applications/orca-ide.desktop" \
        --replace-fail 'Exec=AppRun' 'Exec=orca'

      cp -R ${contents}/usr/share/icons "$out/share/icons"
    '';

    meta = meta // {
      mainProgram = "orca";
    };
  }
else
  stdenvNoCC.mkDerivation {
    inherit pname src version;

    nativeBuildInputs = [ undmg ];
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/Applications"
      cp -R Orca.app "$out/Applications/Orca.app"
      runHook postInstall
    '';

    # Never mutate the signed and notarized upstream app bundle.
    dontFixup = true;

    inherit meta;
  }
