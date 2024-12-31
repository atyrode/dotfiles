{ config, pkgs, ... }:

{
  home.username = "user";
  home.homeDirectory = "/home/user";

  programs.bash = {
    enable = true;
    shellInit = ''
      export EDITOR=vim
      export PATH=$HOME/.local/bin:$PATH
    '';
  };

  home.packages = with pkgs; [
    git
    vim
    htop
  ];

  services = {
    ssh-agent.enable = true;
  };

  files = {
    ".vimrc".text = ''
      set number
      syntax on
    '';
    ".bash_aliases".text = ''
      alias ll="ls -la"
    '';
  };
}
