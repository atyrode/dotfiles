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

_nix_dotfiles_source_nix() {
  if (( ${+commands[nix]} )); then
    return 0
  fi

  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    source "$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi
}

_nix_dotfiles_backup_if_symlink() {
  local path="$1"

  if [[ ! -L "$path" ]]; then
    return 0
  fi

  local target
  zmodload zsh/stat 2>/dev/null || true
  target="$(zstat -L +link -- "$path" 2>/dev/null || echo "${path:A}")"
  case "$target" in
    /nix/store/*-home-manager-files/*|/nix/store/*-hm_..zshrc|/nix/store/*-hm_..zshenv)
      return 0
      ;;
  esac

  local backup="$path.backup"
  if [[ -e "$backup" || -L "$backup" ]]; then
    zmodload zsh/datetime 2>/dev/null || true
    if (( ${+EPOCHSECONDS} )); then
      backup="$path.backup.$(strftime "%Y%m%d%H%M%S" "$EPOCHSECONDS")"
    else
      backup="$path.backup.$$"
    fi
  fi

  echo -e "$(c_folder "Backing up") existing symlink: $path -> $backup"
  zmodload zsh/files 2>/dev/null || true
  mv "$path" "$backup"
}

_nix_dotfiles_backup_symlink_conflicts() {
  _nix_dotfiles_backup_if_symlink "$HOME/.zshrc"
  _nix_dotfiles_backup_if_symlink "$HOME/.zshenv"
}

_nix_dotfiles_should_restart_shell() {
  [[ "${NIX_DOTFILES_RESTART_SHELL:-0}" == "1" ]] || return 1
  [[ -z "${CODEX_SHELL:-}${CODEX_CI:-}${CODEX_SANDBOX:-}" ]] || return 1
  [[ -t 0 && -t 1 ]] || return 1
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

  _nix_dotfiles_source_nix

  echo -e "$(c_folder "Switching") Home Manager from: $flake_dir#$flake_config"
  HOME_MANAGER_BACKUP_EXT=backup command nix run "$flake_dir#home-manager" -- switch --flake "$flake_dir#$flake_config" || {
    echo -e "$(c_ko "Home Manager switch failed")"
    return 1
  }

  # Reload HM session vars (PATH, etc.) for this shell. Restarting the shell is
  # opt-in because replacing the terminal process can hang embedded terminals.
  if [[ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]]; then
    source "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
  fi

  if _nix_dotfiles_should_restart_shell; then
    exec zsh -l
  fi

  echo -e "$(c_ok "Home Manager switch complete.")"
  echo -e "Run $(c_file "exec zsh -l") or open a new terminal to reload the shell."
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
    local package_groups=(
      cliPackages
      pythonPackages
      javascriptPackages
      developmentPackages
    )

    case "$flake_config" in
      *-darwin) package_groups+=(darwinPackages) ;;
      *-linux) package_groups+=(linuxPackages) ;;
    esac

    for package_group in "${package_groups[@]}"; do
      awk -v group="$package_group" '
      $0 ~ "^[[:space:]]*" group " = with pkgs; \\[" { in_list = 1; next }
      in_list && /^[[:space:]]*\];/ { in_list = 0; next }
      in_list {
        if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*\[/ && $0 !~ /^[[:space:]]*\]/ && $0 !~ /^[[:space:]]*$/) {
          gsub(/^[[:space:]]+|[[:space:]]+$|,$/, "", $0)
          if ($0 ~ /^[a-zA-Z0-9_]+$/) {
            print $0
          }
        }
      }' "$packages_file"
    done | sort -u | \
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
        sed -E 's/[[:space:]]*\(\)[[:space:]]*\{.*$//' | \
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
      sed 's/[[:space:]]*=.*$//' | \
      sed 's/^[[:space:]]*//' | \
      while read -r git_alias; do
        echo -e "  $(c_file "•") git $git_alias"
      done
    echo ""
  fi

  # Extract and display zsh plugins
  if [[ -f "$zsh_file" ]]; then
    echo -e "$(c_ok "🎨 Zsh Plugins:")"
    awk '
    /plugins = \[/ { in_list = 1; next }
    in_list && /^[[:space:]]*\]/ { in_list = 0; next }
    in_list {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^"[a-zA-Z0-9_-]+"/) {
        gsub(/^"/, "", line)
        gsub(/".*$/, "", line)
        if (line != "") print line
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
