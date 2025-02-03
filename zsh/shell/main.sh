# Shortcuts clear to cl
alias cl="clear"

# Zoxide to replace cd
eval "$(zoxide init --cmd cd zsh)"

# Replaces Ctrl + R search with fzf
eval "$(fzf --zsh)"

# Utility replacements          # src --> new

alias find="fd"                 # find --> fd
alias cat="bat"                 # cat --> bat
alias htop="btop"               # htop --> btop
alias ls="tree -L 1 --noreport" # ls --> tree
