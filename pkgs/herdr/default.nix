{
  fetchurl,
  lib,
  stdenv,
}:

let
  version = "0.7.4";
  sources = {
    "x86_64-linux" = {
      asset = "herdr-linux-x86_64";
      hash = "sha256-vA/ALUulAPnKwjU6Q+Z/4DZ4Xsym61U3jgUPrDwQMFk=";
    };
    "aarch64-linux" = {
      asset = "herdr-linux-aarch64";
      hash = "sha256-VE4AAt5CgG0atkzN7zp+dBTyRxewtrAivJ5X0u79JqI=";
    };
    "x86_64-darwin" = {
      asset = "herdr-macos-x86_64";
      hash = "sha256-3fQwEzNS4XEkE9XYZbNKSFVG9GWIk/yJmGJX1lp1hag=";
    };
    "aarch64-darwin" = {
      asset = "herdr-macos-aarch64";
      hash = "sha256-JJkuFiXb3LGDVKWeKZ5LJjwxJACzE5bNwHzUbtV/JKc=";
    };
  };
  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported herdr platform: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "herdr";
  inherit version;

  # Release assets are the bare executables (musl-static on Linux, so no ELF
  # interpreter patching), published with per-asset sha256 digests. nixpkgs
  # carries herdr, but upstream releases outpace it and the trial (#269)
  # depends on v0.7.4 fixes (OMP lifecycle report retry, refreshed skill), so
  # this stays repository-owned like the other agent binaries. The pinned
  # binary lives under /nix/store, which herdr detects to hard-disable its
  # self-updater; updates flow through scripts/update-pins.sh.
  src = fetchurl {
    url = "https://github.com/ogulcancelik/herdr/releases/download/v${version}/${source.asset}";
    inherit (source) hash;
  };

  dontUnpack = true;
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/herdr"
    runHook postInstall
  '';

  postFixup = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out/share/zsh/site-functions"
    "$out/bin/herdr" completion zsh > "$out/share/zsh/site-functions/_herdr"
  '';

  meta = {
    description = "Terminal workspace manager for AI coding agents";
    homepage = "https://github.com/ogulcancelik/herdr";
    changelog = "https://github.com/ogulcancelik/herdr/releases/tag/v${version}";
    license = lib.licenses.agpl3Plus;
    mainProgram = "herdr";
    platforms = builtins.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
