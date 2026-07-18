# Carry the atyrode/herdr fork during the sidebar-sections trial. If the trial
# ends, resume pinning upstream release binaries instead of carrying this fork.
{
  callPackage,
  cctools ? null,
  fetchFromGitHub,
  git,
  lib,
  pkg-config,
  runCommand,
  rustPlatform,
  stdenv,
  xcbuild ? null,
  zig_0_15,
  zstd,
}:

let
  version = "0.7.4";
  forkRev = "d7a84fb3479f70dd50b3b084c0ff06f9e6a563d0";

  src = fetchFromGitHub {
    owner = "atyrode";
    repo = "herdr";
    rev = forkRev;
    hash = "sha256-zvUT6ASHsQy1XH0x0LJPLQwHwBwJQ1K1WC1m0b1F8a0=";
  };

  zigDeps = callPackage "${src}/vendor/libghostty-vt/build.zig.zon.nix" {
    name = "herdr-libghostty-vt-zig-cache";
    inherit zstd;
    linkFarm =
      name: entries:
      runCommand name { } ''
        mkdir -p "$out"
        ${lib.concatMapStringsSep "\n" (entry: ''
          cp -rL ${entry.path} "$out/${entry.name}"
        '') entries}
      '';
  };
in
rustPlatform.buildRustPackage {
  pname = "herdr";
  inherit src version;

  cargoHash = "sha256-XHzZy2tKLbMQy4POmXowUcGf77ZPunG/oQ3P2wOoVls=";

  nativeBuildInputs = [
    git
    pkg-config
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    cctools
    xcbuild
  ];

  env = {
    LIBGHOSTTY_VT_OPTIMIZE = "ReleaseFast";
    LIBGHOSTTY_VT_SIMD = "true";
    LIBGHOSTTY_VT_ZIG_SYSTEM_DIR = zigDeps;
    ZIG = lib.getExe zig_0_15;
  };

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
  '';

  doCheck = false;

  postFixup = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$out/share/zsh/site-functions"
    "$out/bin/herdr" completion zsh > "$out/share/zsh/site-functions/_herdr"
  '';

  passthru.forkRev = forkRev;

  meta = {
    description = "Terminal workspace manager for AI coding agents";
    homepage = "https://github.com/ogulcancelik/herdr";
    changelog = "https://github.com/ogulcancelik/herdr/releases/tag/v${version}";
    license = lib.licenses.agpl3Plus;
    mainProgram = "herdr";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
