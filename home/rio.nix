{ pkgs, ... }:

{
  # Rio (#278): the single pinned cross-platform terminal layer.
  # Terminal-as-thin-renderer under the existing stack — herdr owns
  # multiplexing, OMP owns the agent layer, Nix owns config and pins.
  # Adopted as THE terminal after the #278 trial (Ghostty retired in the
  # cutover; operator-validated 2026-07-19).
  #
  # The config is a literal committed TOML (home/rio/config.toml), not a
  # Nix-templated one: the native Windows workstation has no Home Manager
  # and consumes the same artifact verbatim via `atyrode windows apply`
  # (lock artifact: inventory/rio-windows.json, kept at version parity
  # with this nixpkgs pin by checks/rio.nix). Rio reads
  # ~/.config/rio/config.toml on both macOS and Linux.
  home.packages = [
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.rio
  ];

  xdg.configFile."rio/config.toml".source = ./rio/config.toml;
}
