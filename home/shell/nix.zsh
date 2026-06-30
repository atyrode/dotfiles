############################################
# Nix / Home Manager utilities
############################################

_dotfiles_system() {
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

_dotfiles_config() {
  if [[ -n "${DOTFILES_CONFIG:-}" ]]; then
    echo "$DOTFILES_CONFIG"
    return 0
  fi

  local system
  system="$(_dotfiles_system)" || return 1

  local active_config_file
  active_config_file="$(_dotfiles_active_config_file)"
  if [[ -r "$active_config_file" ]]; then
    local active_config
    read -r active_config < "$active_config_file"

    if [[ -n "$active_config" ]] && _dotfiles_config_matches_system "$active_config" "$system"; then
      echo "$active_config"
      return 0
    fi
  fi

  echo "alex-$system"
}

_dotfiles_dir() {
  if [[ -n "${DOTFILES:-}" ]]; then
    echo "$DOTFILES"
  elif [[ -f "./flake.nix" ]]; then
    echo "$PWD"
  elif [[ -f "$HOME/dotfiles/flake.nix" ]]; then
    echo "$HOME/dotfiles"
  elif [[ -f "$HOME/code/dotfiles/flake.nix" ]]; then
    echo "$HOME/code/dotfiles"
  else
    echo -e "$(c_ko "Could not find flake.nix"). Set DOTFILES or run from the repo."
    return 1
  fi
}

_dotfiles_active_config_file() {
  echo "${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/dotfiles-config"
}

_dotfiles_config_matches_system() {
  local flake_config="$1"
  local system="$2"

  case "$system:$flake_config" in
    *-darwin:*linux*|*-linux:*darwin*) return 1 ;;
    *) return 0 ;;
  esac
}

_dotfiles_record_active_config() {
  local flake_config="$1"
  local active_config_file
  active_config_file="$(_dotfiles_active_config_file)"

  mkdir -p "${active_config_file:h}" || return 1
  printf '%s\n' "$flake_config" > "$active_config_file"
}

_dotfiles_reload_shell_modules() {
  local flake_dir="$1"
  local shell_dir="$flake_dir/home/shell"

  [[ -d "$shell_dir" ]] || return 0

  source "$shell_dir/colors.zsh"
  source "$shell_dir/utils.zsh"
  source "$shell_dir/aliases.zsh"
  source "$shell_dir/codex.zsh"
  source "$shell_dir/python.zsh"
  source "$shell_dir/git.zsh"
  source "$shell_dir/nix.zsh"
  source "$shell_dir/tmux.zsh"
}

_dotfiles_source_nix() {
  if (( ${+commands[nix]} )); then
    return 0
  fi

  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
    source "$HOME/.nix-profile/etc/profile.d/nix.sh"
  fi
}

_dotfiles_backup_if_symlink() {
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

_dotfiles_backup_symlink_conflicts() {
  _dotfiles_backup_if_symlink "$HOME/.zshrc"
  _dotfiles_backup_if_symlink "$HOME/.zshenv"
}

_dotfiles_should_restart_shell() {
  [[ "${DOTFILES_RESTART_SHELL:-0}" == "1" ]] || return 1
  [[ -z "${CODEX_SHELL:-}${CODEX_CI:-}${CODEX_SANDBOX:-}" ]] || return 1
  [[ -t 0 && -t 1 ]] || return 1
}

_dotfiles_switch_home_manager() {
  local flake_dir="$1"
  local flake_config="$2"

  echo -e "$(c_folder "Switching") Home Manager from: $flake_dir#$flake_config"
  HOME_MANAGER_BACKUP_EXT=backup command nix run "$flake_dir#home-manager" -- switch --flake "$flake_dir#$flake_config" || {
    echo -e "$(c_ko "Home Manager switch failed")"
    return 1
  }
}

_dotfiles_switch_darwin() {
  local flake_dir="$1"
  local flake_config="$2"
  local nix_config="${NIX_CONFIG:-extra-experimental-features = nix-command flakes}"

  echo -e "$(c_folder "Switching") nix-darwin from: $flake_dir#$flake_config"
  echo -e "$(c_folder "Elevating") nix-darwin activation with sudo"

  if (( ${+commands[darwin-rebuild]} )); then
    local darwin_rebuild_cmd="${commands[darwin-rebuild]}"

    if (( EUID == 0 )); then
      command "$darwin_rebuild_cmd" switch --flake "$flake_dir#$flake_config" || {
        echo -e "$(c_ko "nix-darwin switch failed")"
        return 1
      }
    else
      command sudo -H env NIX_CONFIG="$nix_config" "$darwin_rebuild_cmd" switch --flake "$flake_dir#$flake_config" || {
        echo -e "$(c_ko "nix-darwin switch failed")"
        return 1
      }
    fi
  else
    local nix_cmd="${commands[nix]}"

    if (( EUID == 0 )); then
      command "$nix_cmd" run "$flake_dir#darwin-rebuild" -- switch --flake "$flake_dir#$flake_config" || {
        echo -e "$(c_ko "nix-darwin switch failed")"
        return 1
      }
    else
      command sudo -H env NIX_CONFIG="$nix_config" "$nix_cmd" run "$flake_dir#darwin-rebuild" -- switch --flake "$flake_dir#$flake_config" || {
        echo -e "$(c_ko "nix-darwin switch failed")"
        return 1
      }
    fi
  fi
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
  # - uses $DOTFILES if you set it
  # - otherwise tries current dir, ~/dotfiles, then ~/code/dotfiles
  local flake_dir
  flake_dir="$(_dotfiles_dir)" || return 1

  local system
  system="$(_dotfiles_system)" || return 1

  local flake_config
  flake_config="$(_dotfiles_config)" || return 1

  _dotfiles_backup_symlink_conflicts

  _dotfiles_source_nix

  if [[ "$system" == *-darwin && "${DOTFILES_FORCE_HOME_MANAGER:-0}" != "1" ]]; then
    _dotfiles_switch_darwin "$flake_dir" "$flake_config" || return 1
  else
    _dotfiles_switch_home_manager "$flake_dir" "$flake_config" || return 1
  fi

  if ! _dotfiles_record_active_config "$flake_config"; then
    echo -e "$(c_ko "Could not record active dotfiles configuration")"
  fi

  # Reload HM session vars (PATH, etc.) for this shell. Restarting the shell is
  # opt-in because replacing the terminal process can hang embedded terminals.
  if [[ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]]; then
    source "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
  fi

  _dotfiles_reload_shell_modules "$flake_dir"

  if _dotfiles_should_restart_shell; then
    exec zsh -l
  fi

  echo -e "$(c_ok "Configuration switch complete.")"
  echo -e "Run $(c_file "exec zsh -l") or open a new terminal to reload the shell."
}

############################################
# Help function - lists all dotfiles content
############################################

_dotfiles_package_description() {
  case "$1" in
    android-tools) echo "ADB and Fastboot tools for Android devices." ;;
    arduino-ide) echo "Arduino development IDE." ;;
    bat) echo "cat replacement with syntax highlighting and paging." ;;
    bitwarden) echo "Bitwarden password manager desktop app." ;;
    btop) echo "Interactive terminal system monitor." ;;
    bubblewrap) echo "Linux sandboxing helper used by some desktop tools." ;;
    bun) echo "JavaScript runtime, package manager, and test runner." ;;
    cargo) echo "Rust package manager and build tool." ;;
    chatgpt) echo "OpenAI ChatGPT desktop app." ;;
    clamav) echo "Open-source malware scanner." ;;
    clippy) echo "Rust linter." ;;
    codex) echo "OpenAI Codex CLI." ;;
    codex-use) echo "Local helper for switching Codex profiles." ;;
    deno) echo "Secure JavaScript and TypeScript runtime." ;;
    direnv) echo "Loads per-directory shell environments." ;;
    discord) echo "Discord desktop chat app." ;;
    display-pilot) echo "BenQ Display Pilot monitor control app." ;;
    dive) echo "Docker image layer inspector." ;;
    docker) echo "Docker container engine CLI package for Linux." ;;
    docker-compose) echo "Docker Compose CLI for multi-container projects." ;;
    dua) echo "Interactive disk usage analyzer." ;;
    fastfetch) echo "Fast terminal system information summary." ;;
    fd) echo "Fast, user-friendly file finder." ;;
    ffmpeg) echo "Audio and video conversion and inspection tools." ;;
    fzf) echo "Command-line fuzzy finder." ;;
    gcc) echo "GNU C/C++ compiler toolchain for Linux." ;;
    gh) echo "GitHub CLI." ;;
    git) echo "Version control system." ;;
    go) echo "Go compiler and tooling." ;;
    godot) echo "Godot game engine editor." ;;
    jq) echo "Command-line JSON processor." ;;
    lichess) echo "Launcher for lichess.org." ;;
    nixd) echo "Nix language server." ;;
    nixfmt) echo "Official Nix formatter." ;;
    nmap) echo "Network scanner and diagnostic tool." ;;
    nodejs_24) echo "Node.js 24 JavaScript runtime." ;;
    obsidian) echo "Obsidian Markdown notes app." ;;
    orbstack) echo "Lightweight macOS containers and Linux machines app." ;;
    parsec) echo "Low-latency remote desktop and game streaming app." ;;
    parsec-bin) echo "Low-latency remote desktop and game streaming app." ;;
    plugdata) echo "Pure Data-based visual programming environment and audio plugin host." ;;
    postman) echo "API client and testing app." ;;
    prismlauncher) echo "Minecraft launcher for modded instances." ;;
    python3) echo "Python interpreter with Pillow bundled for image work." ;;
    reaper) echo "Digital audio workstation." ;;
    ripgrep) echo "Fast recursive text search." ;;
    rust-analyzer) echo "Rust language server." ;;
    rustc) echo "Rust compiler." ;;
    rustfmt) echo "Rust formatter." ;;
    scrcpy) echo "Android screen mirroring and control tool." ;;
    shellcheck) echo "Shell script linter." ;;
    shfmt) echo "Shell script formatter." ;;
    signal-desktop) echo "Signal private messenger desktop app." ;;
    socat) echo "General-purpose socket relay and networking tool." ;;
    sonos) echo "Sonos desktop controller app." ;;
    spotify) echo "Spotify desktop music app." ;;
    steam) echo "Steam game launcher." ;;
    steamcmd) echo "Steam command-line client for server and game file workflows." ;;
    tmux) echo "Terminal multiplexer." ;;
    tree) echo "Directory tree printer." ;;
    uv) echo "Fast Python package and project manager." ;;
    vital) echo "Spectral warping wavetable synthesizer." ;;
    vlc) echo "VLC media player." ;;
    vlc-bin) echo "VLC media player app bundle for macOS." ;;
    vscode) echo "Visual Studio Code editor." ;;
    whatsapp-for-mac) echo "WhatsApp desktop app." ;;
    zen) echo "Zen Browser, installed through Homebrew on macOS." ;;
    zoxide) echo "Smart cd replacement based on directory history." ;;
    *) echo "Configured package from this dotfiles setup." ;;
  esac
}

_dotfiles_extract_nix_package_group() {
  local file="$1"
  local group="$2"

  awk -v group="$group" '
  BEGIN {
    assignment = group
    gsub(/[][\\.^$*+?(){}|]/, "\\\\&", assignment)
  }
  $0 ~ "^[[:space:]]*" assignment "[[:space:]]*=[[:space:]]*with pkgs;[[:space:]]*\\[" {
    in_list = 1
    next
  }
  in_list && /^[[:space:]]*\];/ {
    in_list = 0
    next
  }
  in_list {
    line = $0
    sub(/#.*/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    gsub(/,$/, "", line)

    if (line == "") next

    if (in_python_packages) {
      if (line ~ /^\]\)/ || line ~ /^\]\]\)/ || line ~ /^\]\)\)/) {
        in_python_packages = 0
      }
      next
    }

    if (line ~ /^\(python3\.withPackages/) {
      print "python3"
      in_python_packages = 1
      next
    }

    if (line ~ /^[A-Za-z0-9_][A-Za-z0-9_+.-]*$/) {
      print line
    }
  }' "$file"
}

_dotfiles_extract_homebrew_casks() {
  local file="$1"

  awk '
  /^[[:space:]]*casks[[:space:]]*=[[:space:]]*\[/ {
    in_list = 1
    next
  }
  in_list && /^[[:space:]]*\];/ {
    in_list = 0
    next
  }
  in_list {
    line = $0
    sub(/#.*/, "", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line ~ /^"[^"]+"/) {
      gsub(/^"/, "", line)
      gsub(/".*$/, "", line)
      if (line != "") print line
    }
  }' "$file"
}

_dotfiles_print_package_lines() {
  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    echo -e "  $(c_file "•") $(c_file "$pkg") - $(_dotfiles_package_description "$pkg")"
  done
}

atyrode() {
  # Find the dotfiles directory (same logic as zconf)
  local flake_dir
  flake_dir="$(_dotfiles_dir)" || return 1

  local flake_config
  flake_config="$(_dotfiles_config)" || return 1

  local packages_file="$flake_dir/home/packages.nix"
  local linux_desktop_file="$flake_dir/home/linux-desktop.nix"
  local darwin_file="$flake_dir/darwin/default.nix"
  local shell_dir="$flake_dir/home/shell"
  local git_file="$flake_dir/home/git.nix"
  local zsh_file="$flake_dir/home/zsh.nix"

  echo -e "\n$(c_folder "==== Dotfiles Help ====")\n"
  echo -e "$(c_ok "Active configuration:") $flake_config\n"

  # Extract and display packages (simple text parsing - works reliably)
  if [[ -f "$packages_file" ]]; then
    echo -e "$(c_ok "📦 Nix Packages for $flake_config:")"
    local package_groups=(
      cliPackages
      pythonPackages
      javascriptPackages
      developmentPackages
    )

    case "$flake_config" in
      *darwin*) package_groups+=(darwinPackages) ;;
    esac

    case "$flake_config" in
      *linux*) package_groups+=(linuxPackages) ;;
    esac

    for package_group in "${package_groups[@]}"; do
      _dotfiles_extract_nix_package_group "$packages_file" "$package_group"
    done | sort -u | _dotfiles_print_package_lines
    echo ""
  fi

  if [[ "$flake_config" == *linux-desktop* && -f "$linux_desktop_file" ]]; then
    echo -e "$(c_ok "🖥️ Linux Desktop Nix Packages:")"
    _dotfiles_extract_nix_package_group "$linux_desktop_file" "home.packages" | sort -u | _dotfiles_print_package_lines
    echo ""
  fi

  if [[ "$flake_config" == *darwin* && -f "$darwin_file" ]]; then
    echo -e "$(c_ok "🍺 macOS Homebrew Casks:")"
    _dotfiles_extract_homebrew_casks "$darwin_file" | sort -u | \
      while read -r cask; do
        [[ -n "$cask" ]] && echo -e "  $(c_file "•") $(c_file "$cask") - $(_dotfiles_package_description "$cask")"
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
