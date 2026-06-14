{ pkgs, lib, ... }:

let
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
