############################################
# Nix / Home Manager compatibility
############################################

# Keep the historical entry point while the packaged CLI becomes the shared
# operator/agent interface. The CLI owns discovery, preflight, and activation.
zconf() {
  command atyrode apply "$@" || return

  # Refresh only Home Manager's realized session environment. Full shell
  # startup is intentionally left to a new login shell to avoid double-loading
  # plugins or replacing an embedded terminal process.
  if [[ -r "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]]; then
    source "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
  fi
  rehash

  echo "Configuration switch complete. Run 'exec zsh -l' or open a new terminal."
}
