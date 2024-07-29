#!/bin/bash

dotfiles_firefox_dir="$PWD"

# Navigate to the Firefox Profiles directory, assuming MacOS for now
cd "/Users/alex/Library/Application Support/Firefox/Profiles"

# Find the folder ending in .default-release
profile_folder=$(ls | grep ".default-release")

# Copy the "chrome" folder from the dotfiles to the profile folder
cp -r "$dotfiles_firefox_dir/chrome" "$profile_folder"