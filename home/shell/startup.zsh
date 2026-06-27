############################################
# Startup footer
############################################

_should_run_fastfetch() {
  [[ -o interactive ]] || return 1
  [[ "${DOTFILES_FASTFETCH:-1}" != "0" ]] || return 1
  [[ -z "${DOTFILES_FASTFETCH_SHOWN:-}" ]] || return 1
  [[ -z "${CI:-}" ]] || return 1
  [[ -z "${SSH_CONNECTION:-}" ]] || return 1
  [[ "${TERM_PROGRAM:-}" != "vscode" ]] || return 1
}

if _should_run_fastfetch; then
  export DOTFILES_FASTFETCH_SHOWN=1
  fastfetch
fi

# Machine-local overrides, not managed by this repo.
[[ -r "$HOME/.config/zsh/local.zsh" ]] && source "$HOME/.config/zsh/local.zsh"
