{ pkgs, ... }:

{
  home.packages = with pkgs; [
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

    # Python tooling
    (python3.withPackages (ps: with ps; [
      pillow
    ]))
    uv

    # JavaScript/TypeScript tooling
    nodejs_20
    bun

    # Container tools
    docker
    docker-compose
    dive

    # Development tools
    git
    gh
    tmux
    gcc
    cargo
    rustc
    rustfmt
    clippy
    rust-analyzer
    codex
    bubblewrap
  ];
}
