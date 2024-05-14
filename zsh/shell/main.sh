# Shortcut to source ~/.zshrc
alias zconf="source ~/.zshrc"

# Zoxide to replace cd
alias cd="z"
eval "$(zoxide init zsh)"

# Replaces Ctrl + R search with fzf
eval "$(fzf --zsh)"
