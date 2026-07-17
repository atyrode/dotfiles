_:

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

      # Ghostty shell integration, guarded on the file actually existing:
      # cmux (libghostty) sets GHOSTTY_RESOURCES_DIR to its own app bundle,
      # which does not ship Ghostty's integration at this path (cmux injects
      # its own vendored copy instead). Real Ghostty auto-injects too; this
      # covers nested interactive shells.
      if [[ -n "$GHOSTTY_RESOURCES_DIR" && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]]; then
        source "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
      fi
    '';
  };
}
