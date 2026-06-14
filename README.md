# nix-dotfiles

Nix + Home Manager configuration for shell and developer tooling on macOS and Linux.

## 🚀 Quick Start

**From this checkout:**

```bash
cd ~/code/nix-dotfiles
./install.sh
```

**One command installation from GitHub:**

```bash
curl -fsSL https://raw.githubusercontent.com/atyrode/nix-dotfiles/main/install.sh | bash
```

Or manually:

```bash
# 1. Install Nix (if not installed)
sh <(curl -L https://nixos.org/nix/install) --daemon
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

# 2. Enable flakes
mkdir -p ~/.config/nix
echo "extra-experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# 3. Clone and setup
git clone https://github.com/atyrode/nix-dotfiles.git ~/nix-dotfiles
cd ~/nix-dotfiles
if [ -L ~/.zshrc ]; then mv ~/.zshrc ~/.zshrc.backup.$(date +%Y%m%d%H%M%S); fi
HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#alex-aarch64-darwin

# 4. Restart shell
exec zsh
```

**That's it!** Your shell is now configured. Run `atyrode` to see all available tools.

---

## 📦 What's Included

### Shell & Navigation
- **Zsh** with oh-my-zsh, syntax highlighting, autosuggestions
- **zoxide** - Smarter `cd` command
- **fzf** - Fuzzy finder (Ctrl+R for history)
- **bat** - Better `cat` with syntax highlighting
- **tree** - Directory tree viewer

### Development Tools
- **Python 3** + **uv** - Modern Python package manager
- **Node.js 20** + **Bun** - JavaScript runtime
- **Git** - Pre-configured with useful aliases
- **GCC** - Native compiler for Rust/C build scripts
- **tmux** - Terminal multiplexer
- **Rust tooling** - cargo, rustc, rustfmt, clippy, and rust-analyzer

### System & Containers
- **btop** - Modern system monitor
- **dua** - Disk usage analyzer
- **Docker** + **docker-compose** + **dive** - Container tools on Linux configs
- **fastfetch** - System info on startup

---

## 🛠️ Custom Functions

Run `atyrode` to see everything, or check these highlights:

### Python Virtual Environments
```bash
venv          # Create/activate venv in current directory
pipreq        # Install from requirements.txt
pipfreeze     # Freeze current packages
revenv        # Recreate venv from scratch
unvenv        # Remove venv
```

### Nix/Home Manager
```bash
zconf         # Reload dotfiles configuration
atyrode       # Show help and list all tools
```

### Git Helpers
```bash
hub <repo>    # Clone your GitHub repo and setup Python env
```

### Git Aliases
```bash
git st        # git status
git co        # git checkout
git br        # git branch
git ci        # git commit
```

---

## 🔄 Updating

**Update dotfiles:**
```bash
cd ~/nix-dotfiles
git pull
zconf
```

**Update Nix packages:**
```bash
cd ~/nix-dotfiles
nix flake update
zconf
```

---

## 📁 Structure

```
nix-dotfiles/
├── flake.nix              # Main flake configuration
├── install.sh             # Quick install script
└── home/                  # Home Manager modules
    ├── default.nix        # Main configuration
    ├── packages.nix       # Package definitions
    ├── zsh.nix            # Zsh configuration
    ├── git.nix            # Git configuration
    └── shell/             # Modular shell functions
        ├── colors.zsh     # Color helpers
        ├── utils.zsh      # Utility functions
        ├── aliases.zsh    # Shell aliases
        ├── python.zsh     # Python venv management
        ├── git.zsh        # Git helpers
        ├── nix.zsh        # Nix/Home Manager utils
        ├── tmux.zsh       # Tmux utilities
        └── startup.zsh    # Startup commands
```

---

## ⚙️ Customization

### System Configurations

The installer detects the current system and selects the matching configuration:

```bash
alex-aarch64-darwin
alex-x86_64-darwin
alex-aarch64-linux
alex-x86_64-linux
```

For this Mac, the manual switch command is:

```bash
HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#alex-aarch64-darwin
```

### Change Username

Edit `flake.nix` and replace `defaultUsername = "alex"` with your username.

If you want to keep the username but force a config, set `FLAKE_CONFIG` before running the installer.

### Add Packages

Edit `home/packages.nix` and add to the `home.packages` list, then run `zconf`.

### Modify Shell Functions

Edit files in `home/shell/` - they're organized by category for easy maintenance.

---

## 🐛 Troubleshooting

**"Path is not tracked by Git" error:**
```bash
cd ~/nix-dotfiles
git add <file>
zconf
```

**Note:** Nix flakes require referenced files to be tracked by Git. After adding new files, run `git add <file>` before `zconf`.

**Nix not found after install:**
```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
# Or restart your terminal
```

**Home Manager switch fails:**
```bash
# Check if all files are tracked
git status
zconf
```

If the error says an existing symlink such as `~/.zshrc` would be clobbered,
run `./install.sh` instead of the manual switch command. The installer backs up
symlinked shell entrypoints before activation.

---

## 📝 Requirements

- macOS or Linux with Nix support
- Git
- Internet connection (for initial install)

Nix will be installed automatically if not present.

---

## 🔗 Links

- [Nix](https://nixos.org/)
- [Home Manager](https://github.com/nix-community/home-manager)
