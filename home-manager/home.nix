{ config, pkgs, ... }:

{
  home.username = "alex";
  home.homeDirectory = "/home/alex";
  home.stateVersion = "24.11";

  home.packages = [
    pkgs.zsh
  ];

  home.file = {
    ".zshrc".source = ../dotfiles/zsh/.zshrc;
  };

  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  programs.home-manager.enable = true;
}
