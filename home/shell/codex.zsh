############################################
# Codex profile helpers
############################################

# These helpers only choose a CODEX_HOME profile. Credentials, auth.json files,
# sessions, logs, caches, and connector state stay outside this dotfiles repo in
# ~/.codex and ~/.codex-alt.

_codex_profile() {
  local nix_codex_profile="$HOME/.nix-profile/bin/codex-profile"

  if [[ -x "$nix_codex_profile" ]]; then
    "$nix_codex_profile" "$@"
  else
    command codex-profile "$@"
  fi
}

alias codex-main="_codex_profile cli default"
alias codex-alt="_codex_profile cli alt"

alias codex-app-main="_codex_profile app default"
alias codex-app-alt="_codex_profile app alt"

alias codex-side-main="_codex_profile app-instance default"
alias codex-side-alt="_codex_profile app-instance alt"

codex-both() {
  _codex_profile app-instance default "$@"
  _codex_profile app-instance alt "$@"
}
