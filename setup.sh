#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

CWD=$(pwd)

echo "1. Navigating to the 'home' directory..."
cd $HOME

echo "2. Creating a backup folder (.dotfiles-backup)..."
mkdir -p .config-backup

echo "3. Cloning the dotfiles repository..."
git clone git@github.com:atyrode/dotfiles.git || { echo "Cloning failed"; exit 1; }

echo "4. Navigating to the dotfiles directory..."
cd dotfiles

echo -n "5. Configuration"
echo -n "o) Please enter your first name (default: Alex):"
read FIRST_NAME
FIRST_NAME=${FIRST_NAME:-Alex}

echo -n "o) Please enter your last name (default: TYRODE):"
read LAST_NAME
LAST_NAME=${LAST_NAME:-TYRODE}

# Capitalize the first letter of the first name
FIRST_NAME=$(echo $FIRST_NAME | awk '{print toupper(substr($0, 1, 1)) tolower(substr($0, 2))}')

# Capitalize the last name
LAST_NAME=$(echo $LAST_NAME | awk '{print toupper($0)}')

echo -n "o) Please enter your PERSONAL email address (default: alex.tyrode@outlook.fr):"
read PERSONAL_EMAIL
PERSONAL_EMAIL=${PERSONAL_EMAIL:-alex.tyrode@outlook.fr}

echo -n "o) Please enter your WORK email address (default: alex.tyrode@alouette.ai):"
read WORK_EMAIL
WORK_EMAIL=${WORK_EMAIL:-alex.tyrode@alouette.ai}


(
    export FIRST_NAME=$FIRST_NAME
    export LAST_NAME=$LAST_NAME
    export WORK_EMAIL=$WORK_EMAIL
    export PERSONAL_EMAIL=$PERSONAL_EMAIL

    # Find directories in the current directory and execute main.sh if it exists
    for dir in */ ; do
        if [[ -d "$dir" && -f "${dir}main.sh" ]]; then
        echo "Executing main.sh in $dir"
        (bash "${dir}main.sh")
        fi
    done
)

# Step 5: Source the new .zshrc to apply the configuration
source ~/.zshrc

echo "Configuration set up successfully!"