# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="robbyrussell"

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

source $ZSH/oh-my-zsh.sh

# Get the directory of the current script (.zshrc)
DOTFILES_DIR="$(dirname "$(realpath "$HOME/.zshrc")")"

# List of configuration files to source
CONFIG_FILES=(
    "src/color.sh"      # Color management
    "src/utils.sh"      # Utility functions
    "shell"             # Shell configuration (directory, note no .sh extension)
    "python"            # Python configuration (directory as well)
    "node"              # Node configuration (directory as well)
    "git"               # Git configuration (directory as well)
    "src/footer.sh"     # End of configuration/start up behavior
)

# Source all configuration files
for file in "${CONFIG_FILES[@]}"; do

    if [[ -d "$DOTFILES_DIR/$file" ]]; then

        # If it's a directory, source main.sh first and then all other .sh files
        # This is because main.sh of the folder acts as the entry point that other files can use
        if [[ -f "$DOTFILES_DIR/$file/main.sh" ]]; then
            source "$DOTFILES_DIR/$file/main.sh"
        fi
        for sh_file in "$DOTFILES_DIR/$file"/*.sh; do
            [[ "$sh_file" != "$DOTFILES_DIR/$file/main.sh" ]] && source "$sh_file"
        done

    else
        # If it's a regular file, source it directly
        source "$DOTFILES_DIR/$file"
    fi
done
