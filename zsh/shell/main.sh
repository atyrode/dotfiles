# Shortcuts clear to cl
alias cl="clear"

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
eval "$(zoxide init --cmd cd zsh)"

# Replaces Ctrl + R search with fzf
eval "$(fzf --zsh)"

# Fd to replace find
alias find="fd"

# Bat to replace cat
alias cat="bat"

# Btop to replace htop
alias htop="btop"

# Tree to replace ls
alias ls="tree -L 1 --noreport"

# Quick attach to tmux session
alias atmux="tmux attach-session -t"