{ pkgs, ... }:

{
  # Rio trial (#278): the single pinned cross-platform terminal layer.
  # Terminal-as-thin-renderer under the existing stack — herdr owns
  # multiplexing, OMP owns the agent layer, Nix owns config and pins.
  # Runs ALONGSIDE Ghostty until the trial gates in #278 pass; the clean
  # cutover (retiring home/ghostty.nix and the zsh integration guard)
  # happens only after live validation on the Mac and the Windows box.
  #
  # The config is a literal committed TOML (home/rio/config.toml), not a
  # Nix-templated one: the native Windows workstation has no Home Manager
  # and consumes the same artifact verbatim via `atyrode windows apply`
  # (lock artifact: inventory/rio-windows.json, kept at version parity
  # with this nixpkgs pin by checks/rio.nix). Rio reads
  # ~/.config/rio/config.toml on both macOS and Linux.
  home.packages = [ pkgs.rio ];

  xdg.configFile."rio/config.toml".source = ./rio/config.toml;
}
