# Quick search for processes
pfind() {
    ps aux | grep "$1" | grep -v grep | awk '{print $2 "\t" $11}'
}

# Quick attach to tmux session
alias atmux="tmux attach-session -t"

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
