#!/bin/bash

# If the file "~/.gitconfig" exists, move it in .dotfiles-backup
if [[ -f "$HOME/.gitconfig" ]]; then
    echo "Moving the existing .gitconfig file to .dotfiles-backup..."
    mv "$HOME/.gitconfig" "$HOME/.dotfiles-backup/.gitconfig"
fi

