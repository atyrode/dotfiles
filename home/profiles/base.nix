{ pkgs, ... }:
{
  imports = [
    ../git.nix
    ../mise.nix
    ../zsh.nix
  ];

  # Home Manager uses this as a compatibility marker for stateful defaults.
  # Keep it fixed after first activation unless every skipped release note has
  # been reviewed explicitly.
  home.stateVersion = "26.05";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    atyrode
    bat
    btop
    direnv
    dua
    fd
    fastfetch
    git
    jq
    ripgrep
    tree
    unzip
  ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf = {
    enable = true;
    # fzf's generated zshrc hook restores shell options via eval, and
    # restoring the zle option fails ("can't change option: zle") in
    # interactive shells without a TTY — which is every agent eval shell.
    # The TTY-guarded replacement lives in home/zsh.nix. (#255)
    enableZshIntegration = false;
  };
  programs.zoxide.enable = true;
}
