#!/bin/bash

# Some of this code is based on the install.sh of Homebrew (https://brew.sh)

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

# Fail fast with a concise message when not using bash
# Single brackets are needed here for POSIX compatibility
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ]
then
  abort "Bash is required to interpret this script."
fi

# string formatters
if [[ -t 1 ]]
then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_yellow="$(tty_mkbold 33)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"
  do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

caution() {
  printf "${tty_yellow}[?]${tty_bold} %s${tty_reset} %s\n" "$(chomp "$1")" >&2
}

warn() {
  printf "${tty_red}/!\\${tty_bold} %s${tty_reset} %s\n" "$(chomp "$1")" >&2
}

# USER isn't always set so provide a fall back for the installer and subprocesses.
if [[ -z "${USER-}" ]]
then
  USER="$(chomp "$(id -un)")"
  export USER
fi

# First check OS.
OS="$(uname)"
if [[ "${OS}" == "Linux" ]]
then
  INSTALL_ON_LINUX=1
elif [[ "${OS}" == "Darwin" ]]
then
  INSTALL_ON_MACOS=1
else
  abort "Only macOS and Linux are supported."
fi

execute() {
  if ! "$@"
  then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}

execute_sudo() {
  local -a args=("$@")
  if [[ "${EUID:-${UID}}" != "0" ]] && have_sudo_access
  then
    if [[ -n "${SUDO_ASKPASS-}" ]]
    then
      args=("-A" "${args[@]}")
    fi
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  else
    ohai "${args[@]}"
    execute "${args[@]}"
  fi
}

### End of Homebrew code ###

# Function to execute on script exit
cleanup() {
  ohai "Cleaning up before exit..."
  
  # Check if the directories exist before attempting to remove them
  if [ -d "$HOME/dotfiles" ]; then
    caution "Directory $HOME/dotfiles exists."
    read -p "Are you sure you want to delete $HOME/dotfiles? (y/N) " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      execute "rm" "-rf" "$HOME/dotfiles"
      ohai "$HOME/dotfiles has been deleted."
    else
      ohai "Skipping deletion of $HOME/dotfiles."
    fi
  else
    ohai "Directory $HOME/dotfiles does not exist."
  fi

  if [ -d "$HOME/.dotfiles-backup" ]; then
    caution "Directory $HOME/.dotfiles-backup exists."
    read -p "Are you sure you want to delete $HOME/.dotfiles-backup? (y/N) " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      execute "rm" "-rf" "$HOME/.dotfiles-backup"
      ohai "$HOME/.dotfiles-backup has been deleted."
    else
      ohai "Skipping deletion of $HOME/.dotfiles-backup."
    fi
  else
    ohai "Directory $HOME/.dotfiles-backup does not exist."
  fi
  
  # Add any other cleanup commands here, with appropriate checks and confirmations
}

# Trap the EXIT signal to run the cleanup function
trap cleanup EXIT


############### Main script ###############

CWD=$(pwd)

# If option "-s" skip the change to the home directory
if [[ "$1" == "-s" ]]; then
  ohai "Skipping the change to the home directory"
else
  ohai "Navigating to the home ($HOME) directory"
  execute "cd" "$HOME"
fi

ohai "Creating a backup folder (.dotfiles-backup)"
if [[ -d .dotfiles-backup ]]; then
  warn "The .dotfiles-backup directory already exists. Please back up your existing configuration files."
  exit 1
else
  mkdir .dotfiles-backup
fi

(
    backup() {
      if [ -f "$1" ]; then
          echo "Moving the existing file (at '$1') to .dotfiles-backup..."
          mv "$1" "$HOME/.dotfiles-backup/$1"
      fi
    }

    install() {
        FILENAME=$(basename "$1")
        echo "Installing $1..."
        backup $2
        mv "$1" "$2"
    }

    export -f backup
    export -f install

    # Find directories in the current directory and execute setup.sh if it exists
    ohai "Checking for setup.sh files in directories of $PWD"
    ohai "List of directories:"
    ls -d */

    for dir in */ ; do
        if [[ -d "$dir" && -f "${dir}setup.sh" ]]; then
            ohai "Setting up: $dir"
            (bash "${dir}setup.sh")
        else 
            warn "No setup.sh found in $dir"
        fi
    done
)

echo "Configuration set up successfully!"