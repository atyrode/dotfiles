{ pkgs, ... }:

{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true; # Enable zsh-autosuggestions
    syntaxHighlighting.enable = true; # Enable zsh-syntax-highlighting

    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
      plugins = [ "git" ];
    };

    # Load custom shell functions (in order)
    initContent = ''
      # Load shell configuration modules
      source ${./shell/colorterm.zsh}
      source ${./shell/nix.zsh}
      source ${./shell/startup.zsh}
    '';
  };

  home.sessionVariables.SHELL = "${pkgs.zsh}/bin/zsh";
}
