# dotfiles

Reproducible, agent-first personal operating environment for [Alex Tyrode](https://tyrode.dev). Nix and Home Manager own macOS, Linux, and the NixOS-WSL guest; nix-darwin owns macOS system activation, and native package managers retain macOS and Windows application state.

## Quick start

**From a reviewed checkout:**

```bash
cd ~/nix-dotfiles
./bootstrap/install.sh plan --config platform-01
./bootstrap/install.sh apply --config platform-01
```

**Supported fresh-machine command:**

```bash
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash
```

The fetched `get.sh` clones the repository, lists the registered presets for
the detected platform, and asks which one to install before handing off to the
cloned `install.sh`. Each choice describes what it installs;
`atyrode capabilities list` shows the same descriptions per capability later.
Cloning first and running `./bootstrap/install.sh apply --config <host>`
yourself remains equivalent.

For portable Linux automation, pass the generic profile for the detected
architecture, for example `bash -s -- development-x86_64-linux --yes`.
Bootstrap validates explicit names and will not guess between portable, fixed,
desktop, or Mac profiles. It uses explicit preflight, plan, apply, and verify
phases, verifies a pinned upstream Nix artifact when Nix is absent, and marks
an interrupted apply so the next run can warn and recover.
See [Bootstrap](docs/bootstrap.md).

**Native Windows 11, from PowerShell:**

```powershell
irm https://raw.githubusercontent.com/atyrode/dotfiles/main/get.ps1 | iex
```

That command is plan-only. It resolves `main` to an exact commit and reports the
native/WSL changes without applying them. After review, run the printed revision:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/atyrode/dotfiles/main/get.ps1))) -Ref <exact-revision> -Apply
```

The bootstrap verifies a pinned NixOS-WSL image, activates
`wsl`, and then reconciles reviewed native packages through
WinGet. If it first enables or updates WSL, follow its reboot instruction and
run the same apply command again.

---

## What's included

### Shell & Navigation
- **Zsh** with oh-my-zsh, syntax highlighting, autosuggestions
- **zoxide** - Smarter `cd` command
- **fzf** - Fuzzy finder (Ctrl+R for history)
- **bat** - Better `cat` with syntax highlighting
- **tree** - Directory tree viewer

### Development Tools
- **Git** - Pre-configured with useful aliases
- **tmux** - Terminal multiplexer
- **Nix/shell/workflow quality tooling** - nixd, nixfmt, ShellCheck, shfmt, and actionlint
- **OMP** - Pinned coding agent, the `code` profile generator, agents, and skills
- **mise** - Declaratively installed runtime/version manager
- **Project-owned runtimes** - Python/uv, general JavaScript runtimes, Go, Rust,
  and native compilers come from committed dev shells, `mise.toml`, or native
  manifests instead of every host's global profile; Node 24 and Bun are the
  deliberate agent-tools exceptions for local review proxies

### System & Containers
- **btop** - Modern system monitor
- **dua** - Disk usage analyzer
- **Docker** + **docker-compose** - Linux clients in the `containers` capability
- **OrbStack** - Docker/Linux runtime on macOS
- **Explicit capabilities** - ffmpeg (`media`), Android tools/scrcpy (`mobile`),
  and nmap/socat/sops (`security`, plus age-plugin-se on macOS)

### macOS Apps
- **Nix/Home Manager apps** - ChatGPT, Lichess, Obsidian, OrbStack,
  Postman, Prism Launcher, REAPER, Signal, Spotify, and VLC
- **Homebrew casks** - Arduino IDE, Bitwarden, Claude Desktop, Codex Desktop,
  Discord, Display Pilot, Godot, Parsec, PlugData, Sonos, Steam, and Zen Browser
  Twilight, managed through nix-darwin
- **Manual/vendor-managed macOS apps** - ROLI Connect, ROLI Dashboard, ROLI
  Studio Player, and Vital stay outside the declarative setup until they have a
  stable public installer or package source.

### Native Windows Apps
- **WinGet packages** - Zen Browser Twilight and the JetBrainsMono Nerd Font
  are declared in `fleet/windows-packages.nix` and reconciled from the managed
  NixOS-WSL host.
- **Application state** - Mozilla sign-in, Zen profiles, cookies, sessions,
  updates, and caches remain owned by Zen/Windows rather than Nix.

---

## Daily commands

Use the packaged `atyrode` interface, or check these highlights:

### Nix/Home Manager
```bash
atyrode apply --plan  # Inspect the exact host, source, and backend
atyrode apply        # Activate the recorded host configuration
atyrode doctor host   # Validate the managed machine identity
atyrode doctor system # Audit system-owned operational prerequisites
```

### Agent Tools
```bash
code          # Profile generator TUI: type a prompt or turn the facet dials
omp           # Mutable user-owned OMP; profile-aware resume, blocked update
omp-managed   # Managed-layering launch target: defaults + policy over --config
ompu          # Restricted launcher for deliberately untrusted repositories
```

`code` opens a TUI whose facet dials and generated profiles work without local
model services; Ctrl+O optionally classifies the current prompt through the
local Ollama daemon. Enter launches the generated profile for the current
facets through `omp-managed` — the untouched default combo is a profile like
any other. The `m` key runs `omp-managed` on the managed defaults with no
overlay, the `u` key opens the `ompu` sandbox, and plain `omp` is reached by
typing `omp` directly. The model catalog lives in
[`pkgs/omp-configured/config/models.yml`](pkgs/omp-configured/config/models.yml).

OMP, shared skills, and mise are installed by `atyrode apply` with the rest of
the Home Manager profile. See [Agent tools](docs/agent-tools.md) for ownership,
model routing, project skill layout, state ownership, and updates.

### Git Aliases
```bash
git st        # git status
git co        # git checkout
git br        # git branch
git ci        # git commit
```

---

## Updating

**Update dotfiles:**
```bash
cd ~/nix-dotfiles
git pull
atyrode apply
```

**Update Nix packages:**
```bash
cd ~/nix-dotfiles
nix flake update
atyrode apply
```

Pinned OMP updates have additional hash and integration checks documented in
[Agent tools](docs/agent-tools.md#updating).

---

## Repository structure

```
dotfiles/
├── .agents/                 # Repository-local agent skills (bump-omp)
├── .github/                 # Native Linux/macOS flake-check workflows
├── bootstrap/               # Phased bootstrap with interrupted-apply marker
├── checks/                  # Nix check registry; suites grouped by subject
│   ├── atyrode/             #   the CLI, bootstrap, and the entry points
│   ├── fleet/               #   host, profile, and platform contracts
│   ├── lints/               #   whole-tree lints and CI plumbing
│   ├── omp/                 #   the managed OMP stack
│   ├── fixtures/            #   shared fixtures
│   └── lib/                 #   shared fixture builders
├── ci/                      # Path classifier, drift guard, pin refresh, CI constants
├── docs/                    # Architecture and maintenance guides
├── fleet/                   # Every place a machine is named: registries and inventories
├── lib/                     # Flake library: targets, packages, configurations
├── modules/
│   ├── darwin/              #   nix-darwin and Homebrew configuration
│   ├── home/                #   Home Manager modules, one directory per tool, and capability profiles
│   ├── nixos/               #   Repository-owned NixOS-WSL system module
│   └── shared/              #   Modules every activation kind imports
├── pkgs/                    # Pinned derivations and wrappers, each with what it deploys
├── secrets/                 # sops-encrypted secrets, one file per audience
├── flake.nix                # Inputs and output assembly
├── get.ps1                  # Plan-first native Windows/NixOS-WSL bootstrap
└── get.sh                   # Fresh macOS/Linux bootstrap entrypoint
```

---

## Customization

### System Configurations

The installer detects the current system and selects the matching
configuration. The authoritative registry lives in
[Hosts and capabilities](docs/hosts.md); list the registered targets and their
capabilities with `atyrode capabilities list`. Production NixOS servers
consume the exported `base + server + agent-tools` profile from their
infrastructure flake instead of appearing in this personal host registry.
Host IDs are canonical and have no compatibility aliases.

[Portable Home Manager profiles](docs/portable-profiles.md) documents the
external NixOS interface, one-way infrastructure dependency, server manifest,
closure budget, and pin/update workflow.

[The `atyrode` CLI](docs/atyrode.md) documents deterministic application,
machine-readable capability discovery, and diagnostics.

[Package ownership](docs/package-ownership.md) records the checked agent
baseline, optional capabilities, project-owned runtimes, harness boundaries,
and closure review workflow.

[Home Manager and system boundary](docs/system-boundary.md) records which
layer owns login shells, the Nix daemon, containers, device access, antivirus,
and Homebrew, plus the read-only operational readiness checks.

[Shell surface](docs/shell.md) documents the current interactive startup
surface, ownership, and verification.

[Codex state](docs/codex-state.md) documents the one-time defaults seed, the
managed guidance files, and secret/mutable ownership.

For this Mac, the manual switch command is:

```bash
sudo -H nix run .#darwin-rebuild -- switch --flake .#macbook
```

`atyrode apply` uses nix-darwin on macOS and asks for sudo when system
activation is required.

On Linux, the matching configuration still uses Home Manager directly:

```bash
HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#platform-01
```

For Linux desktop machines that need Steam, SteamCMD, and VLC:

```bash
HOME_MANAGER_BACKUP_EXT=backup nix run .#home-manager -- switch --flake .#workstation-x86_64-linux
```

You can also set `ATYRODE_HOST=workstation-x86_64-linux` before running
`atyrode apply` on a Linux desktop. Successful `atyrode apply` and
`bootstrap/install.sh apply` runs record the active configuration so helper
commands only show what applies to the current setup.

### Account identity

Portable Linux bootstrap profiles resolve the invoking user and canonical home
at activation time; no repository edit is needed when the login name changes.
Fixed machine identities remain in `fleet/hosts.nix` and deliberately require
their declared user and home. See [Hosts and capabilities](docs/hosts.md).

### Add Packages

Add the package to its owning module under `modules/home/profiles/`, update the checked
package inventory, then run `atyrode apply`.

### Add macOS Homebrew Apps

Edit `modules/darwin/casks.nix`, then run `atyrode apply` on macOS. nix-darwin
generates the matching Brewfile; Homebrew Bundle shows any undeclared state and
asks before removing it during activation.

---

## Troubleshooting

**"Path is not tracked by Git" error:**
```bash
cd ~/nix-dotfiles
git add <file>
atyrode apply
```

**Note:** Nix flakes require referenced files to be tracked by Git. After adding new files, run `git add <file>` before `atyrode apply`.

**Nix not found after install:**
```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
# Or restart your terminal
```

**Home Manager switch fails:**
```bash
# Check if all files are tracked
git status
atyrode apply
```

If an existing path such as `~/.zshrc` would be clobbered, inspect it, preserve
anything still used in `~/.config/zsh/local.zsh`, then move the old entrypoint
out of the way. Home Manager refuses to guess whether unmanaged shell startup
code is safe to replace.

**macOS Homebrew activation reports undeclared packages:**

Homebrew Bundle lists taps, formulae, or casks absent from the generated
Brewfile and aborts without removing them. Review the reported drift, explicitly
uninstall the entries you intend to retire, then rerun `atyrode apply`. The first
activation may also ask for administrator authentication.

---

## Requirements

- macOS or Linux with Nix support
- Git, Bash, `curl`, `tar`, and either `sha256sum` or `shasum` for a fresh machine
- Internet connection (for initial install)

Nix will be installed automatically if not present.

---

## Links

- [Nix](https://nixos.org/)
- [Home Manager](https://github.com/nix-community/home-manager)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [nix-homebrew](https://github.com/zhaofengli/nix-homebrew)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
- [mise](https://mise.jdx.dev)
