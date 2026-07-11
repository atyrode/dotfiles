{ lib, pkgs, ... }:

lib.mkIf pkgs.stdenv.isDarwin {
  programs.ghostty = {
    enable = true;
    # The ghostty source package does not build on darwin; the binary
    # repackage tracks the official release and stays pinned to nixpkgs.
    package = pkgs.ghostty-bin;

    settings = {
      # Ghostty defaults are deliberately kept: fonts, truecolor, and
      # local COLORTERM already behave without configuration. Remote
      # shells need the SSH integration opted in so xterm-ghostty
      # terminfo is installed on the host and COLORTERM survives the
      # connection; without it remote prompts fall back to 256 colors.
      shell-integration-features = "ssh-env,ssh-terminfo";
    };
  };
}
