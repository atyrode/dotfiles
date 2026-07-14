# dotfiles

Personal dotfiles managed with Nix and Home Manager for shell and developer tooling on macOS and Linux. macOS system activation uses nix-darwin, with Homebrew installed through nix-homebrew for native cask apps.

## 🚀 Quick Start

**From a reviewed checkout:**

```bash
cd ~/nix-dotfiles
./install.sh plan --config alex-x86_64-linux
./install.sh apply --config alex-x86_64-linux
```

**Supported fresh-machine command:**

```bash
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash -s -- alex-x86_64-linux
```

The fetched `get.sh` only clones the repository and hands off to the cloned
`install.sh`; cloning first and running `./install.sh apply --config <host>`
yourself remains equivalent. Omit the host to pick interactively from the
registered presets for this machine, each described with what it installs;
`atyrode capabilities list` shows the same descriptions per capability later.

Replace the example host with the exact entry from `hosts/default.nix`; bootstrap
will not guess between desktop, development, or Mac profiles. It uses
explicit preflight, plan, apply, verify, and rollback phases, verifies a pinned
upstream Nix artifact when Nix is absent, and preserves recoverable migration
receipts. See [Bootstrap and migrations](docs/bootstrap.md).

---

## 📦 What's Included

### Shell & Navigation
- **Zsh** with oh-my-zsh, syntax highlighting, autosuggestions
- **zoxide** - Smarter `cd` command
- **fzf** - Fuzzy finder (Ctrl+R for history)
- **bat** - Better `cat` with syntax highlighting
- **tree** - Directory tree viewer

### Development Tools
- **Git** - Pre-configured with useful aliases
- **tmux** - Terminal multiplexer
- **Nix/shell quality tooling** - nixd, nixfmt, ShellCheck, and shfmt
- **OMP** - Pinned coding agent, the `code` profile generator, agents, and skills
- **mise** - Declaratively installed runtime/version manager
- **Project-owned runtimes** - Python/uv, JavaScript runtimes, Go, Rust, and
  native compilers come from committed dev shells, `mise.toml`, or native
  manifests instead of every host's global profile

### System & Containers
- **btop** - Modern system monitor
- **dua** - Disk usage analyzer
- **Docker** + **docker-compose** - Linux clients in the `containers` capability
- **OrbStack** - Docker/Linux runtime on macOS
- **dive** - Docker image inspector
- **fastfetch** - Explicit system information command (not a startup side effect)
- **Explicit capabilities** - ffmpeg (`media`), Android tools/scrcpy (`mobile`),
  and nmap/socat (`security`)

### macOS Apps
- **Nix app bundles** - ChatGPT, Godot, Lichess, Obsidian, OrbStack, Postman,
  Prism Launcher, REAPER, Signal, Spotify, VLC, and WhatsApp
- **Homebrew casks** - Arduino IDE, Bitwarden, Claude Desktop, Codex Desktop, Discord, Display
  Pilot, Parsec, PlugData, Sonos, Steam, and Zen Browser, managed through
  nix-darwin
- **Manual/vendor-managed macOS apps** - ROLI Connect, ROLI Dashboard, ROLI
  Studio Player, and Vital stay outside the declarative setup until they have a
  stable public installer or package source.

---

## 🛠️ Custom Functions

Use the packaged `atyrode` interface, or check these highlights:

### Nix/Home Manager
```bash
atyrode apply --plan  # Inspect the exact host, source, and backend
zconf                 # Compatibility wrapper for `atyrode apply`
atyrode doctor host   # Validate the managed machine identity
atyrode doctor system # Audit system-owned operational prerequisites
```

### Agent Tools
```bash
code          # Profile generator TUI: type a prompt or turn the facet dials
omp           # Mutable user-owned OMP; unmanaged except the blocked update
omp-managed   # Managed-layering launch target: defaults + policy over --config
ompu          # Restricted launcher for deliberately untrusted repositories
```

`code` opens a TUI with a prompt→profile classifier on the local ollama daemon.
Enter with nothing changed runs your default `omp`; type a prompt or move a dial
and it generates a managed profile, launching it through `omp-managed`. The `u`
key opens the `ompu` sandbox. The model catalog lives in
[`omp/models.yml`](omp/models.yml).

OMP, shared skills, and mise are installed by `zconf`
with the rest of the Home Manager profile. See
[Agent tools](docs/agent-tools.md) for ownership, model routing, project skill
layout, migration behavior, and updates.

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

Pinned OMP updates have additional hash and compatibility
checks documented in [Agent tools](docs/agent-tools.md#updating).

---

## 📁 Structure

```
dotfiles/
├── .github/workflows/       # Native Linux/macOS flake checks
├── agents/                  # Generic cross-project skills
├── checks/                  # Nix package and migration checks
├── darwin/                # nix-darwin and Homebrew configuration
│   ├── casks.nix          # Shared declarative Homebrew cask list
│   └── default.nix        # macOS system ownership and activation
├── docs/                    # Architecture and maintenance guides
├── flake.nix              # Main flake configuration
├── install.sh             # Phased, transactional bootstrap
├── modules/                 # Reusable Home Manager modules
├── omp/                     # Managed config, model catalog, agents, and rules
├── pkgs/                    # Pinned custom derivations and wrappers
├── scripts/                 # Activation-time migration and seeding logic
└── home/                  # Home Manager modules
    ├── default.nix        # Main configuration
    ├── linux-desktop.nix  # Optional Linux desktop packages
    ├── profiles/          # Composable host capability modules
    ├── zsh.nix            # Zsh configuration
    ├── git.nix            # Git configuration
    └── shell/             # Thin interactive shell surface
        ├── nix.zsh        # Temporary zconf compatibility entry point
        └── startup.zsh    # Interactive-only local override hook
```

---

## ⚙️ Customization

### System Configurations

The installer detects the current system and selects the matching configuration:

```bash
alex-aarch64-darwin
alex-aarch64-linux
alex-x86_64-linux
alex-x86_64-linux-desktop
```

These outputs are generated from the authoritative host registry and
composable capability modules. Production NixOS servers consume the exported
`base + server + agent-tools` profile from their infrastructure flake instead
of appearing in this personal host registry. Compatibility aliases such as
`alex`, `alex-linux`, `alex-darwin`, and `alex-linux-desktop` remain available. See
[Hosts and capabilities](docs/hosts.md) for the identity contract and the
add/rename/retire workflow.

[Portable Home Manager profiles](docs/portable-profiles.md) documents the
external NixOS interface, one-way infrastructure dependency, server manifest,
closure budget, and pin/update workflow.

[The `atyrode` CLI](docs/atyrode.md) documents deterministic application,
machine-readable capability discovery, diagnostics, and the `zconf`
compatibility boundary.

[Package ownership](docs/package-ownership.md) records the checked agent
baseline, optional capabilities, project-owned runtimes, harness boundaries,
and closure review workflow.

[Home Manager and system boundary](docs/system-boundary.md) records which
layer owns login shells, the Nix daemon, containers, device access, antivirus,
and Homebrew, plus the read-only operational readiness checks.

[Shell surface](docs/shell.md) records every retained and removed function,
alias, startup side effect, and Oh My Zsh plugin.

[Codex state](docs/codex-state.md) documents the one-time defaults seed, the
managed guidance files, and secret/mutable ownership.

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

You can also set `ATYRODE_HOST=alex-x86_64-linux-desktop` before running
`zconf` on a Linux desktop. Successful `zconf` and `install.sh apply` runs
record the active configuration so helper commands such as `atyrode` only show
what applies to the current setup.

### Change Username

Edit the owning entry in `hosts/default.nix`, including its username and home
directory, then follow the validation workflow in [Hosts and
capabilities](docs/hosts.md). Select a bootstrap host with `--config`; the
`FLAKE_CONFIG` environment variable is the equivalent non-interactive input.

### Add Packages

Add the package to its owning module under `home/profiles/`, update the checked
package inventory, then run `atyrode apply`.

### Add macOS Homebrew Apps

Edit `darwin/casks.nix`, then run `zconf` on macOS. nix-darwin generates the
matching Brewfile and checks for non-destructive Homebrew drift.

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

If the error says an existing path such as `~/.zshrc` would be clobbered, run
the bootstrap plan and apply phases for the registered host. The versioned
migration backs up file and symlink entrypoints before activation and restores
them automatically if activation fails.

```sh
./install.sh plan --config <host>
./install.sh apply --config <host>
```

**macOS Homebrew activation fails:**
```bash
zconf
```

The macOS configuration installs Homebrew through nix-homebrew and then applies the declared casks through nix-darwin. The first activation may ask for administrator authentication.

---

## 📝 Requirements

- macOS or Linux with Nix support
- Git, Bash, `curl`, `tar`, and either `sha256sum` or `shasum` for a fresh machine
- Internet connection (for initial install)

Nix will be installed automatically if not present.

---

## 🔗 Links

- [Nix](https://nixos.org/)
- [Home Manager](https://github.com/nix-community/home-manager)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [nix-homebrew](https://github.com/zhaofengli/nix-homebrew)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
- [mise](https://mise.jdx.dev)
