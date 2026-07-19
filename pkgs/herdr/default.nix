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
  forkRev = "daac065a3001e2097c96fe6586c5205e431bc830";

  src = fetchFromGitHub {
    owner = "atyrode";
    repo = "herdr";
    rev = forkRev;
    hash = "sha256-QPn77mkTG7f+zHyY894KfSzZ3IbHzYnzAOsxUSoWIDM=";
  };

  # Vendored copy of "${src}/vendor/libghostty-vt/build.zig.zon.nix" (zon2nix
  # output, reflowed by treefmt; semantically identical — herdr's drvPath is
  # unchanged on all three flake systems: x86_64-linux, aarch64-linux,
  # aarch64-darwin).
  # Importing it from ${src} is IFD: evaluating any x86_64 host on an aarch64
  # evaluator (CI matrix, `nix flake check`) then has to *build* the x86_64
  # source fetch at eval time and dies with a platform mismatch. Refresh the
  # copy from the fork checkout whenever forkRev changes.
  zigDeps = callPackage ./libghostty-vt-deps.nix {
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
