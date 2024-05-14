# Shortcut to source ~/.zshrc
function zconf() {
    # Deactivate the current virtual environment if one is active
    if [[ $VIRTUAL_ENV ]]; then
        deactivate
        echo -e "$(c_ok Deactivated) virtual environment."
    fi

    # Clear all old aliases
    unalias -a
    echo -e "$(c_ok Cleared) old aliases."

    # Source the zsh configuration file
    source ~/.zshrc
    echo -e "$(c_ok Sourced) ~/.zshrc."
}


# Zoxide to replace cd
alias cd="z"
eval "$(zoxide init zsh)"

# Replaces Ctrl + R search with fzf
eval "$(fzf --zsh)"
