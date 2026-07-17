{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.isDarwin {
  programs.ghostty = {
    enable = true;
    # Home Manager's generated zshrc hook sources
    # $GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration guarded
    # only by the variable being set. cmux (libghostty) exports
    # GHOSTTY_RESOURCES_DIR into its own bundle, which lacks Ghostty's layout,
    # so every cmux pane printed "no such file or directory" at startup. The
    # guarded replacement lives in home/zsh.nix; real Ghostty auto-injects its
    # integration regardless, so nothing is lost there.
    enableZshIntegration = false;
    # The ghostty source package does not build on darwin; the binary
    # repackage tracks the official release and stays pinned to nixpkgs.
    package = pkgs.ghostty-bin;

    settings = {
      # Ghostty defaults are deliberately kept: fonts, truecolor, and
      # local COLORTERM already behave without configuration. Remote
      # shells need the SSH integration opted in so xterm-ghostty
      # terminfo is installed on the host. ssh-env also sends COLORTERM,
      # but sshd only admits variables listed in AcceptEnv (stock installs
      # accept LANG/LC_* only), so home/shell/colorterm.zsh re-derives it
      # from TERM on the remote side.
      shell-integration-features = "ssh-env,ssh-terminfo";
    };
  };
}
