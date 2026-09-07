# shellcheck shell=bash
set -eu

@mkdir@ -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" \
  "$XDG_STATE_HOME" "$XDG_STATE_HOME/nix/profiles"
unset __HM_SESS_VARS_SOURCED
# shellcheck disable=SC1091
source @sessionVariables@

# Driver 0 owns generation/profile installation and the managed-file conflict
# checks. Activation must run on every start, including a reused writable home.
if @activation@ >&2; then
  exec "$@"
else
  status=$?
  printf 'development-image: Home Manager activation failed (status %s)\n' "$status" >&2
  exit "$status"
fi
