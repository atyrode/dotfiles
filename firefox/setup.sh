#!/bin/bash

dotfiles_firefox_dir="$PWD"

# Navigate to the Firefox Profiles directory, assuming MacOS for now
if [[ "$OSTYPE" == "darwin"* ]]; then
  cd "/Users/$(whoami)/Library/Application Support/Firefox/Profiles"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  cd "/home/$(whoami)/.mozilla/firefox"
else
  echo "Unsupported OS"
  exit 1
fi

# Find the folder ending in .default-release
profile_folder=$(ls | grep ".default-release")

# Copy the "chrome" folder from the dotfiles to the profile folder
cp -r "$dotfiles_firefox_dir/chrome" "$profile_folder"