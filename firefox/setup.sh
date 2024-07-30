#!/bin/bash

# Dotfiles directory in the repository
firefox_dotfiles_dir="$PWD/chrome"

# Firefox profile name
target_profile="arcfox"
# Firefox profile directory
firefox_profile_dir="/Users/alex/Library/Application Support/Firefox/Profiles"

# Copy the dotfiles to the target firefox profile directory
cp -r "$firefox_dotfiles_dir" "$firefox_profile_dir/$target_profile"