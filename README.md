# dotfiles

Personal dotfiles managed with Nix and Home Manager for shell and developer tooling on macOS and Linux. macOS system activation uses nix-darwin, with Homebrew installed through nix-homebrew for native cask apps.

## 🚀 Quick Start

**From this checkout:**

```bash
cd ~/code/dotfiles
./install.sh
```

**One command installation from GitHub:**

```bash
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/install.sh | bash
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
git clone https://github.com/atyrode/dotfiles.git ~/dotfiles
cd ~/dotfiles
if [ -L ~/.zshrc ]; then mv ~/.zshrc ~/.zshrc.backup.$(date +%Y%m%d%H%M%S); fi
sudo -H nix run .#darwin-rebuild -- switch --flake .#alex-aarch64-darwin

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
- **Node.js 24** + **Bun** + **Deno** - JavaScript/TypeScript runtimes
- **Git** - Pre-configured with useful aliases
- **GCC** - Native compiler for Rust/C build scripts
- **tmux** - Terminal multiplexer
- **Rust tooling** - cargo, rustc, rustfmt, clippy, and rust-analyzer
- **Nix tooling** - nixd and nixfmt
- **OMP** - Pinned coding agent, model presets, agents, and skills
- **Herdr** - Persistent terminal workspaces for AI coding agents
- **mise** - Declaratively installed runtime/version manager

### System & Containers
- **btop** - Modern system monitor
- **dua** - Disk usage analyzer
- **Docker** + **docker-compose** - Container tools on Linux configs
- **OrbStack** - Docker/Linux runtime on macOS
- **dive** - Docker image inspector
- **fastfetch** - System info on startup
- **ffmpeg**, **Android tools**, **scrcpy**, **nmap**, **socat**, and **clamav**

### macOS Apps
- **Nix app bundles** - ChatGPT, Godot, Lichess, Obsidian, OrbStack, Postman,
  Prism Launcher, REAPER, Signal, Spotify, VLC, VS Code, and WhatsApp
- **Homebrew casks** - Arduino IDE, Bitwarden, Codex Desktop, Discord, Display
  Pilot, Parsec, PlugData, Sonos, Steam, and Zen Browser, managed through
  nix-darwin
- **Manual/vendor-managed macOS apps** - ROLI Connect, ROLI Dashboard, ROLI
  Studio Player, and Vital stay outside the declarative setup until they have a
  stable public installer or package source.

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

### Agent Tools
```bash
omp           # Balanced GPT-5.6 Terra profile
ompb          # Budget profile
ompg          # OpenAI-only high-capability profile
ompo          # GPT profile with selected Opus fallbacks
ompf          # Fable-first profile with fallback disabled
herdr         # Persistent terminal workspace manager
```

OMP, Herdr, their integration, shared skills, and mise are installed by `zconf`
with the rest of the Home Manager profile. See
[Agent tools](docs/agent-tools.md) for ownership, model routing, project skill
layout, migration behavior, and updates.

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
cd ~/code/dotfiles  # or your dotfiles checkout
git pull
zconf
```

**Update Nix packages:**
```bash
cd ~/code/dotfiles  # or your dotfiles checkout
nix flake update
zconf
```

Pinned OMP and Herdr updates have additional hash and compatibility
checks documented in [Agent tools](docs/agent-tools.md#updating).

---

## 📁 Structure

```
dotfiles/
├── .github/workflows/       # Native Linux/macOS flake checks
├── agents/                  # Generic cross-project skills
├── checks/                  # Nix package and migration checks
├── darwin/                # nix-darwin and Homebrew configuration
│   └── default.nix        # macOS system and cask definitions
├── docs/                    # Architecture and maintenance guides
├── flake.nix              # Main flake configuration
├── install.sh             # Quick install script
├── modules/                 # Reusable Home Manager modules
├── omp/                     # Managed config, presets, agents, and rules
├── pkgs/                    # Pinned custom derivations and wrappers
├── scripts/                 # Activation-time migration logic
└── home/                  # Home Manager modules
    ├── default.nix        # Main configuration
    ├── linux-desktop.nix  # Optional Linux desktop packages
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
alex-x86_64-linux-desktop
```

For this Mac, the manual switch command is:

```bash
sudo -H nix run .#darwin-rebuild -- switch --flake .#alex-aarch64-darwin
```

After the first macOS switch, `zconf` uses nix-darwin on macOS and will ask
for sudo when system activation is required.

On Linux, the matching configuration still uses Home Manager directly:

```bash
HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#alex-x86_64-linux
```

For Linux desktop machines that need Steam, SteamCMD, and VLC:

```bash
HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#alex-x86_64-linux-desktop
```

You can also set `DOTFILES_CONFIG=alex-x86_64-linux-desktop` before running
`zconf` on a Linux desktop. Successful `zconf` and `install.sh` runs record
the active configuration so helper commands such as `atyrode` only show what
applies to the current setup.

### Change Username

Edit `flake.nix` and replace `defaultUsername = "alex"` with your username.

If you want to keep the username but force a config, set `FLAKE_CONFIG` before running the installer.

### Add Packages

Edit `home/packages.nix` and add to the `home.packages` list, then run `zconf`.

### Add macOS Homebrew Apps

Edit `darwin/default.nix` and add cask names to `homebrew.casks`, then run `zconf` on macOS.

### Modify Shell Functions

Edit files in `home/shell/` - they're organized by category for easy maintenance.

---

## 🐛 Troubleshooting

**"Path is not tracked by Git" error:**
```bash
cd ~/dotfiles
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

**macOS Homebrew activation fails:**
```bash
zconf
```

The macOS configuration installs Homebrew through nix-homebrew and then applies the declared casks through nix-darwin. The first activation may ask for administrator authentication.

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
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [nix-homebrew](https://github.com/zhaofengli/nix-homebrew)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
- [Herdr](https://herdr.dev)
- [mise](https://mise.jdx.dev)
