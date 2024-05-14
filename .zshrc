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

# Shortcut to source ~/.zshrc
alias zconf="source ~/.zshrc"

# Color management
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

function ok() {
    echo -e "${GREEN}$1${NC}"
}

function ko() {
    echo -e "${RED}$1${NC}"
}

function folder() {
    echo -e "${CYAN}$1${NC}"
}

function file() {
    echo -e "${YELLOW}$1${NC}"
}


# Function to prompt user for yes/no input
function prompt_yes_no() {
    local prompt_message=$1
    local answer

    while true; do
        echo -n "$prompt_message (y/n): "
        read answer
        case $answer in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo -e "Please answer Y (yes) or N (no).";;
        esac
    done
}

# Adds aliases to old Python to uses new Python bindings
alias python="python3"
alias pip="pip3"

# Shortcut to create a python venv in the current folder if one doesn't exist already
# It it exists, acts as a toggle to activate/deactivate the env
# And ensure it's added to the .gitignore at creation
function venv() {
    # Variables
    VENV_DIR="venv"
    PARENT_DIR=$(basename "$(pwd)")
    GITIGNORE=".gitignore"

    # Colored variables representation
    CVD=$(folder $VENV_DIR)
    CPD=$(folder $PARENT_DIR)
    CGI=$(file $GITIGNORE)

    # Ensure venv is in .gitignore
    if [ -e $GITIGNORE ]; then
        if ! grep -q "^$VENV_DIR$" $GITIGNORE; then
            if prompt_yes_no "Do you want to add $CVD to $CGI?"; then
                echo $VENV_DIR >> $GITIGNORE
                echo -e "$CVD added to $CGI in $CPD."
            else
                echo -e "$CVD $(ko "not added") to $CGI."
            fi
        fi
    else
        if prompt_yes_no "$CGI does not exist. Do you want to create it and add $CVD?"; then
            echo $VENV_DIR > $GITIGNORE
            echo -e "$CVD $(ok added) to $CGI in $CPD."
        else
            echo -e "$CGI $(ko "not created") and $CVD $(ko "not added")."
        fi
    fi

    # Create venv if it doesn't exist
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv $VENV_DIR
        echo -e "Virtual environment $CVD $(ok created) in $CPD."
    fi

    # Toggle venv activation
    if [ -z "$VIRTUAL_ENV" ]; then
        source $VENV_DIR/bin/activate
        echo -e "Virtual environment $CVD $(ok activated) in $CPD."
    else
        deactivate
        echo -e "Virtual environment $CVD $(ko deactivated) in $CPD."
    fi
}



# Shortcut to activate python venv if folder is named "venv" and is in PWD
# deactivate will deactivate the env, default existing command
alias activate='source $(pwd)/venv/bin/activate'

# Zoxide to replace cd
alias cd="z"
eval "$(zoxide init zsh)"

# Replaces Ctrl + R search with fzf
eval "$(fzf --zsh)"

