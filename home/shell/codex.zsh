############################################
# Codex profile helpers
############################################

# The actual auth.json files stay machine-local in ~/.codex* and are not
# managed by this public dotfiles repo.

codex-profile-path() {
  local profile="${1:-default}"

  case "$profile" in
    default|main)
      printf '%s\n' "$HOME/.codex-profiles/default"
      ;;
    *)
      printf '%s\n' "$HOME/.codex-profiles/$profile"
      ;;
  esac
}

codex-login-main() {
  codex-use main && codex login --device-auth "$@"
}

codex-login-alt() {
  codex-use alt && codex login --device-auth "$@"
}
