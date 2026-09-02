{ pkgs, ... }:

{
  # Desktop hosts install the JetBrainsMono Nerd Font so terminal UIs render
  # powerline separators and Nerd glyphs instead of tofu, whichever terminal
  # emulator the operator runs. The font is the glyph asset, not a terminal
  # implementation detail, so it stays independent of any one emulator.
  # Headless hosts deliberately do not install it: nothing there renders glyphs,
  # and a font in the profile would be dead weight in the server closure.
  home.packages = [
    pkgs.nerd-fonts.jetbrains-mono
  ];
}
