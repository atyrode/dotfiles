############################################
# Nix / Home Manager utilities
############################################

_nix_dotfiles_system() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) echo "aarch64-darwin" ;;
    Darwin:x86_64) echo "x86_64-darwin" ;;
    Linux:arm64|Linux:aarch64) echo "aarch64-linux" ;;
    Linux:x86_64) echo "x86_64-linux" ;;
    *)
      echo -e "$(c_ko "Unsupported system"): $(uname -s) $(uname -m)"
      return 1
      ;;
  esac
}

_nix_dotfiles_config() {
  if [[ -n "${NIX_DOTFILES_CONFIG:-}" ]]; then
    echo "$NIX_DOTFILES_CONFIG"
    return 0
  fi

  local system
  system="$(_nix_dotfiles_system)" || return 1
  echo "alex-$system"
}

_nix_dotfiles_dir() {
  if [[ -n "${NIX_DOTFILES:-}" ]]; then
    echo "$NIX_DOTFILES"
  elif [[ -f "./flake.nix" ]]; then
    echo "$PWD"
  elif [[ -f "$HOME/nix-dotfiles/flake.nix" ]]; then
    echo "$HOME/nix-dotfiles"
  elif [[ -f "$HOME/code/nix-dotfiles/flake.nix" ]]; then
    echo "$HOME/code/nix-dotfiles"
  else
    echo -e "$(c_ko "Could not find flake.nix"). Set NIX_DOTFILES or run from the repo."
    return 1
  fi
}

_nix_dotfiles_backup_if_symlink() {
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

  echo -e "$(c_folder "Backing up") existing symlink: $path -> $backup"
  mv "$path" "$backup"
}

_nix_dotfiles_backup_symlink_conflicts() {
  _nix_dotfiles_backup_if_symlink "$HOME/.zshrc"
  _nix_dotfiles_backup_if_symlink "$HOME/.zshenv"
}

zconf() {
  # If a venv is active, deactivate it first
  if [[ -n "$VIRTUAL_ENV" ]]; then
    deactivate
    echo -e "$(c_ok "Deactivated") virtual environment."
  fi

  # Clear aliases (keeps your old behavior)
  unalias -a

  # Find the flake directory:
  # - uses $NIX_DOTFILES if you set it
  # - otherwise tries current dir, ~/nix-dotfiles, then ~/code/nix-dotfiles
  local flake_dir
  flake_dir="$(_nix_dotfiles_dir)" || return 1

  local flake_config
  flake_config="$(_nix_dotfiles_config)" || return 1

  _nix_dotfiles_backup_symlink_conflicts

  echo -e "$(c_folder "Switching") Home Manager from: $flake_dir#$flake_config"
  HOME_MANAGER_BACKUP_EXT=backup nix run "$flake_dir#home-manager" -- switch --flake "$flake_dir#$flake_config" || {
    echo -e "$(c_ko "Home Manager switch failed")"
    return 1
  }

  # Reload HM session vars (PATH, etc.) then restart login shell
  if [[ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]]; then
    source "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
  fi

  exec zsh -l
}

############################################
# Help function - lists all dotfiles content
############################################

atyrode() {
  # Find the dotfiles directory (same logic as zconf)
  local flake_dir
  flake_dir="$(_nix_dotfiles_dir)" || return 1

  local flake_config
  flake_config="$(_nix_dotfiles_config)" || return 1

  local packages_file="$flake_dir/home/packages.nix"
  local shell_dir="$flake_dir/home/shell"
  local git_file="$flake_dir/home/git.nix"
  local zsh_file="$flake_dir/home/zsh.nix"

  echo -e "\n$(c_folder "==== Nix Dotfiles Help ====")\n"
  echo -e "$(c_ok "Active configuration:") $flake_config\n"

  # Extract and display packages (simple text parsing - works reliably)
  if [[ -f "$packages_file" ]]; then
    echo -e "$(c_ok "📦 Configured Packages:")"
    awk '
    / = with pkgs; \[/ { in_list = 1; next }
    in_list && /^[[:space:]]*\];/ { in_list = 0; next }
    in_list {
      if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\]/ && $0 !~ /^[[:space:]]*$/) {
        gsub(/^[[:space:]]+|[[:space:]]+$|,$/, "", $0)
        if ($0 ~ /^[a-zA-Z0-9_]+$/) {
          print $0
        }
      }
    }' "$packages_file" | sort -u | \
      while read -r pkg; do
        [[ -n "$pkg" ]] && echo -e "  $(c_file "•") $pkg"
      done
    echo ""
  fi

  # Extract and display shell functions from all .zsh files
  if [[ -d "$shell_dir" ]]; then
    echo -e "$(c_ok "🔧 Custom Shell Functions:")"
    for func_file in "$shell_dir"/*.zsh; do
      [[ -f "$func_file" ]] && \
        grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$func_file" | \
        sed 's/() {.*$//' | \
        sed 's/^[[:space:]]*//' | \
        while read -r func; do
          # Skip internal/private functions starting with _
          [[ "$func" =~ ^_ ]] && continue
          echo -e "  $(c_file "•") $func"
        done
    done | sort -u
    echo ""
  fi

  # Extract and display aliases from all shell files
  if [[ -d "$shell_dir" ]]; then
    echo -e "$(c_ok "🔗 Shell Aliases:")"
    for func_file in "$shell_dir"/*.zsh; do
      [[ -f "$func_file" ]] && \
        grep -E '^alias [a-zA-Z_][a-zA-Z0-9_]*=' "$func_file" | \
        sed 's/alias //' | \
        sed 's/=.*$//' | \
        while read -r alias_name; do
          echo -e "  $(c_file "•") $alias_name"
        done
    done | sort -u
    echo ""
  fi

  # Extract and display git aliases
  if [[ -f "$git_file" ]]; then
    echo -e "$(c_ok "🔀 Git Aliases:")"
    grep -E 'alias\.[a-zA-Z_][a-zA-Z0-9_]*\s*=' "$git_file" | \
      sed 's/alias\.//' | \
      sed 's/\s*=.*$//' | \
      sed 's/^[[:space:]]*//' | \
      while read -r git_alias; do
        echo -e "  $(c_file "•") git $git_alias"
      done
    echo ""
  fi

  # Extract and display zsh plugins
  if [[ -f "$zsh_file" ]]; then
    echo -e "$(c_ok "🎨 Zsh Plugins:")"
    awk '/plugins = \[/,/\]/ {
      if ($0 ~ /"[a-zA-Z0-9_-]+"/) {
        match($0, /"([^"]+)"/, arr)
        if (arr[1] != "") print arr[1]
      }
    }' "$zsh_file" | \
      while read -r plugin; do
        [[ -n "$plugin" ]] && echo -e "  $(c_file "•") $plugin"
      done
    echo ""
  fi

  # Display additional info
  echo -e "$(c_ok "💡 Quick Commands:")"
  echo -e "  $(c_file "•") zconf    - Reload dotfiles configuration"
  echo -e "  $(c_file "•") atyrode  - Show this help message"
  echo ""
  echo -e "$(c_folder "Dotfiles location: $flake_dir")\n"
}
