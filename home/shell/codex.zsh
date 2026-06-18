############################################
# Codex profile helpers
############################################

# The actual auth.json files stay machine-local in ~/.codex* and are not
# managed by this public dotfiles repo. The active profile lives at ~/.codex;
# inactive profiles live under ~/.codex-profiles.

codex-profile-path() {
  codex-use path "$@"
}

codex-login-main() {
  codex-use main && codex login --device-auth "$@"
}

codex-login-alt() {
  codex-use alt && codex login --device-auth "$@"
}
