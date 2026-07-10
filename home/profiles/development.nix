{ pkgs, ... }:
{
  # Cross-repository quality tools that interactive agents may assume. Project
  # language versions and compilers belong to dev shells or mise manifests.
  home.packages = with pkgs; [
    nixd
    nixfmt
    shellcheck
    shfmt
  ];
}
