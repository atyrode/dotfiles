#!/usr/bin/env bash
set -euo pipefail

# Install dotfiles on Linux or macOS.
# Usage:
#   ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/install.sh | bash

REPO_URL="https://github.com/atyrode/dotfiles.git"
DEFAULT_DOTFILES_DIR="${HOME}/dotfiles"

detect_system() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64) echo "aarch64-darwin" ;;
        Darwin:x86_64) echo "x86_64-darwin" ;;
        Linux:arm64|Linux:aarch64) echo "aarch64-linux" ;;
        Linux:x86_64) echo "x86_64-linux" ;;
        *)
            echo "Unsupported system: $(uname -s) $(uname -m)" >&2
            return 1
            ;;
    esac
}

source_nix() {
    if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
        # shellcheck disable=SC1091
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.nix-profile/etc/profile.d/nix.sh"
    fi
}

source_home_manager_session_vars() {
    local session_vars="$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"

    if [[ ! -f "$session_vars" ]]; then
        return 0
    fi

    echo "Loading Home Manager environment..."
    set +u
    # shellcheck disable=SC1090
    . "$session_vars"
    set -u
}

ensure_nix() {
    source_nix

    if command -v nix >/dev/null 2>&1; then
        return 0
    fi

    echo "Installing Nix..."
    sh <(curl -L https://nixos.org/nix/install) --daemon
    source_nix

    if ! command -v nix >/dev/null 2>&1; then
        echo "Nix installation finished, but nix is not available in this shell." >&2
        echo "Open a new terminal, then re-run this script." >&2
        exit 1
    fi
}

ensure_flakes() {
    local nix_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/nix"
    local nix_config="$nix_config_dir/nix.conf"

    echo "Configuring Nix flakes..."
    mkdir -p "$nix_config_dir"

    if ! grep -Eq '^[[:space:]]*(extra-)?experimental-features[[:space:]]*=.*nix-command.*flakes' "$nix_config" 2>/dev/null; then
        printf '\nextra-experimental-features = nix-command flakes\n' >> "$nix_config"
    fi
}

resolve_dotfiles_dir() {
    if [[ -n "${DOTFILES_DIR:-}" ]]; then
        echo "$DOTFILES_DIR"
    elif [[ -f "$PWD/flake.nix" && -d "$PWD/home" ]]; then
        echo "$PWD"
    else
        echo "$DEFAULT_DOTFILES_DIR"
    fi
}

prepare_dotfiles_dir() {
    if [[ -f "$DOTFILES_DIR/flake.nix" && -d "$DOTFILES_DIR/home" ]]; then
        echo "Using existing dotfiles checkout: $DOTFILES_DIR"
        cd "$DOTFILES_DIR"
    elif [[ -d "$DOTFILES_DIR/.git" ]]; then
        echo "Updating existing dotfiles checkout: $DOTFILES_DIR"
        git -C "$DOTFILES_DIR" pull
        cd "$DOTFILES_DIR"
    else
        echo "Cloning dotfiles into: $DOTFILES_DIR"
        git clone "$REPO_URL" "$DOTFILES_DIR"
        cd "$DOTFILES_DIR"
    fi
}

warn_about_untracked_files() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi

    local untracked
    untracked="$(git ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then
        echo "Warning: untracked files are ignored by Nix flakes unless they are added to git:"
        echo "$untracked"
    fi
}

backup_if_symlink() {
    local path="$1"

    if [[ ! -L "$path" ]]; then
        return 0
    fi

    local target
    target="$(readlink "$path")"
    case "$target" in
        /nix/store/*-home-manager-files/*)
            return 0
            ;;
    esac

    local backup="$path.backup"
    if [[ -e "$backup" || -L "$backup" ]]; then
        backup="$path.backup.$(date +%Y%m%d%H%M%S)"
    fi

    echo "Backing up existing symlink: $path -> $backup"
    mv "$path" "$backup"
}

backup_home_manager_symlink_conflicts() {
    # Home Manager's -b backup path does not back up symlinks during collision
    # checks, so handle the expected shell entrypoints before switching.
    backup_if_symlink "$HOME/.zshrc"
    backup_if_symlink "$HOME/.zshenv"
}

switch_configuration() {
    if [[ "$SYSTEM" == *-darwin ]]; then
        local nix_cmd
        nix_cmd="$(command -v nix)"
        local nix_config="${NIX_CONFIG:-extra-experimental-features = nix-command flakes}"

        if [[ "$EUID" -eq 0 ]]; then
            "$nix_cmd" run ".#darwin-rebuild" -- switch --flake ".#$FLAKE_CONFIG"
        else
            sudo env NIX_CONFIG="$nix_config" "$nix_cmd" run ".#darwin-rebuild" -- switch --flake ".#$FLAKE_CONFIG"
        fi
    else
        HOME_MANAGER_BACKUP_EXT=backup nix run ".#home-manager" -- switch --flake ".#$FLAKE_CONFIG"
    fi
}

SYSTEM="$(detect_system)"
FLAKE_CONFIG="${FLAKE_CONFIG:-alex-${SYSTEM}}"
DOTFILES_DIR="$(resolve_dotfiles_dir)"

echo "Installing dotfiles..."
echo "System: $SYSTEM"
echo "Configuration: $FLAKE_CONFIG"

ensure_nix
ensure_flakes
prepare_dotfiles_dir
warn_about_untracked_files
backup_home_manager_symlink_conflicts

echo "Building and activating configuration..."
echo "This may take a few minutes on first run."

if switch_configuration; then
    echo ""
    echo "Installation complete."
    echo ""

    source_home_manager_session_vars

    HM_ZSH=""
    if [[ -f "$HOME/.nix-profile/bin/zsh" ]]; then
        HM_ZSH="$HOME/.nix-profile/bin/zsh"
    elif command -v zsh >/dev/null 2>&1; then
        HM_ZSH="$(command -v zsh)"
    fi

    echo "Next steps:"
    if [[ -n "$HM_ZSH" ]]; then
        echo "   1. Switch to the managed shell now: exec $HM_ZSH"
    else
        echo "   1. Open a new terminal so your shell environment reloads."
    fi
    echo "   2. Run 'atyrode' to see available tools."
    echo "   3. Run 'zconf' after future dotfiles changes."
else
    echo ""
    echo "Installation failed. Try the same switch manually for the full error:"
    echo "   cd $DOTFILES_DIR"
    if [[ "$SYSTEM" == *-darwin ]]; then
        echo "   sudo nix run .#darwin-rebuild -- switch --flake .#$FLAKE_CONFIG"
    else
        echo "   HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#$FLAKE_CONFIG"
    fi
    exit 1
fi
