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

      # Ghostty shell integration, guarded on the file actually existing:
      # libghostty embedders set GHOSTTY_RESOURCES_DIR to their own app
      # bundle, which does not ship Ghostty's integration at this path
      # (#252). Real Ghostty auto-injects too; this covers nested
      # interactive shells.
      if [[ -n "$GHOSTTY_RESOURCES_DIR" && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]]; then
        source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
      fi

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
