{
  appimageTools,
  fetchurl,
  lib,
  stdenv,
  stdenvNoCC,
  undmg,
}:

# Orca is repository-owned because nixpkgs' `orca` is the GNOME screen reader,
# not stablyai/orca. Package the official release artifacts unchanged so every
# agent-tools host receives the same Orca version and the `orca` CLI.
let
  pname = "orca-ide";
  version = "1.4.146";
  sources = {
    "x86_64-linux" = {
      asset = "orca-linux.AppImage";
      hash = "sha256-/DQnU0U4XyOAxYX7J81gCJP2OgaLxTARr4kUpvqdT8k=";
    };
    "aarch64-linux" = {
      asset = "orca-linux-arm64.AppImage";
      hash = "sha256-ZmnwdLtJU59Ck6l27oo1OSLOtUW5OX/hUkx5bCG35rc=";
    };
    "x86_64-darwin" = {
      asset = "orca-macos-x64.dmg";
      hash = "sha256-+1kaF5gkiHghIvCgxc/rp3zLt0PKqLSs3Xsjv56UIdU=";
    };
    "aarch64-darwin" = {
      asset = "orca-macos-arm64.dmg";
      hash = "sha256-svPrsSuRBVelfxOAfiftR6E0WlavRoQo4pjhg8N5YiM=";
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
    mainProgram = "orca";
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

    # `orca serve` automatically starts Xvfb on headless Linux when DISPLAY is
    # unset. Carry it in the FHS environment so a manually started VPS trial
    # needs no host package or service configuration.
    extraPkgs = pkgs: [ pkgs.xorg-server ];

    extraInstallCommands = ''
      ln -s "$out/bin/${pname}" "$out/bin/orca"

      install -Dm444 ${contents}/orca-ide.desktop "$out/share/applications/orca-ide.desktop"
      substituteInPlace "$out/share/applications/orca-ide.desktop" \
        --replace-fail 'Exec=AppRun' 'Exec=orca'

      cp -R ${contents}/usr/share/icons "$out/share/icons"
    '';

    inherit meta;
  }
else
  stdenvNoCC.mkDerivation {
    inherit pname src version;

    nativeBuildInputs = [ undmg ];
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/Applications" "$out/bin"
      cp -R Orca.app "$out/Applications/Orca.app"
      ln -s "$out/Applications/Orca.app/Contents/MacOS/Orca" "$out/bin/orca"
      runHook postInstall
    '';

    # Never mutate the signed and notarized upstream app bundle.
    dontFixup = true;

    inherit meta;
  }
