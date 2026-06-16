{ pkgs, lib, ... }:

let
  codex-profile = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "codex-profile";
    version = "0.2.0-unstable-2026-06-16";

    src = pkgs.fetchFromGitHub {
      owner = "Ducksss";
      repo = "codex-profiles";
      # Pin main until app-instance support lands in a tagged release.
      rev = "6b374f6e25d364f89f774a8275330958fd2d5f6b";
      hash = "sha256-i8s8hbyuhlFBlB+NOEvIACvvIdOcjwSX4mLqK27hLdw=";
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 bin/codex-profile "$out/bin/codex-profile"
      ln -s "$out/bin/codex-profile" "$out/bin/codex-profiles"

      runHook postInstall
    '';

    meta = {
      description = "Isolated CODEX_HOME profiles for Codex CLI and Desktop";
      homepage = "https://github.com/Ducksss/codex-profiles";
      license = lib.licenses.mit;
      platforms = lib.platforms.darwin ++ lib.platforms.linux;
      mainProgram = "codex-profile";
    };
  };

  cliPackages = with pkgs; [
    # File navigation & search
    zoxide
    fzf
    fd
    bat
    tree
    
    # System monitoring
    btop
    dua
    fastfetch
  ];

  pythonPackages = with pkgs; [
    # Python tooling
    (python3.withPackages (ps: with ps; [
      pillow
    ]))
    uv
  ];

  javascriptPackages = with pkgs; [
    # JavaScript/TypeScript tooling
    nodejs_20
    bun
  ];

  developmentPackages = with pkgs; [
    # Development tools
    git
    gh
    tmux
    cargo
    rustc
    rustfmt
    clippy
    rust-analyzer
    codex
    codex-profile
  ];

  darwinPackages = with pkgs; [
    # Add macOS-only packages here.
  ];

  linuxPackages = with pkgs; [
    # Container tools
    docker
    docker-compose
    dive

    # Linux-only development tools
    gcc
    bubblewrap
  ];
in
{
  home.packages =
    cliPackages
    ++ pythonPackages
    ++ javascriptPackages
    ++ developmentPackages
    ++ lib.optionals pkgs.stdenv.isDarwin darwinPackages
    ++ lib.optionals pkgs.stdenv.isLinux linuxPackages;
}
