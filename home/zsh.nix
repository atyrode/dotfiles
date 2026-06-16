{ pkgs, lib, ... }:

{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true; # Enable zsh-autosuggestions
    syntaxHighlighting.enable = true; # Enable zsh-syntax-highlighting

    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [
        "git"
        "tmux"
      ] ++ lib.optionals pkgs.stdenv.isLinux [
        "docker"
        "docker-compose"
      ];
    };

    # Load custom shell functions (in order)
    initContent = ''
      # Load shell configuration modules
      source ${./shell/colors.zsh}
      source ${./shell/utils.zsh}
      source ${./shell/aliases.zsh}
      source ${./shell/codex.zsh}
      source ${./shell/python.zsh}
      source ${./shell/git.zsh}
      source ${./shell/nix.zsh}
      source ${./shell/tmux.zsh}
      source ${./shell/startup.zsh}
    '';
  };
  
  home.sessionVariables.SHELL = "${pkgs.zsh}/bin/zsh";
}
