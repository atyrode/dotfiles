#!/bin/bash

# Set up oh-my-zsh configuration

CWD=$(pwd)

echo "1. Navigating to the 'home' directory..."
cd ~

echo "2. Cloning the dotfiles repository..."
git clone git@github.com:atyrode/dotfiles.git

# Step 3: Checkout the 'macos' branch
cd dotfiles
git checkout macos

# Step 4: Create a symbolic link for .zshrc
ln -s $(pwd)/zsh/.zshrc ~/.zshrc

# Step 5: Source the new .zshrc to apply the configuration
source ~/.zshrc

echo "oh-my-zsh configuration is set up successfully."