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
      source ${./shell/startup.zsh}

      # fzf keybindings and completion, guarded on a real TTY: fzf's own
      # integration save/restores shell options via eval, and restoring the
      # zle option prints "can't change option: zle" in interactive shells
      # without a terminal (agent eval shells). [[ -o zle ]] is not a usable
      # guard — the option reads as on even without a TTY; only writes fail.
      # HM's hook is disabled in home/profiles/base.nix. (#255)
      if [[ -t 0 ]]; then
        source <(${pkgs.fzf}/bin/fzf --zsh)
      fi
    '';
  };
}
