{ pkgs, ... }:
{
  # Cross-repository tooling the operator and interactive agents may assume:
  # quality tools (linters, formatters, Nix editing) and operator deployment
  # CLIs. Project language versions and compilers belong to dev shells or mise
  # manifests.
  home.packages = with pkgs; [
    nixd
    nixfmt
    shellcheck
    shfmt
    clever-tools # Clever Cloud deployment CLI
  ];
}
