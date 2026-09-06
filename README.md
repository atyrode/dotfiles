# dotfiles

Reproducible, agent-first personal operating environment for [Alex Tyrode](https://tyrode.dev): one repository that every machine the operator owns is a projection of. Nix and Home Manager own macOS, Linux, and the NixOS-WSL guest; nix-darwin owns macOS system activation; native package managers retain macOS and Windows application state. The rules this repository holds itself to are in [`AGENTS.md`](AGENTS.md); the documentation map is [`docs/`](docs/README.md), and the commands of a normal week are in [Running the fleet](docs/day-to-day.md).

## Install

macOS or Linux, from nothing but Git and Bash:

```bash
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash
```

It lists the registered presets for this platform, asks which one to install, and hands off to the cloned `bootstrap/install.sh`, which installs the pinned Nix if needed and relays to `atyrode apply`. What bootstrap owns, how it repairs a half-installed machine, and how an interrupted run recovers are in [Bootstrap](docs/bootstrap.md). From then on the only command is `atyrode apply`.

Native Windows 11, from PowerShell, is plan-only by default: it resolves `main` to an exact commit and reports the native and WSL changes without applying them. After review, run the printed revision:

```powershell
irm https://raw.githubusercontent.com/atyrode/dotfiles/main/get.ps1 | iex
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/atyrode/dotfiles/main/get.ps1))) -Ref <exact-revision> -Apply
```

Apply verifies a pinned NixOS-WSL image, activates `wsl`, and reconciles reviewed native packages through WinGet; if it first enables or updates WSL, follow its reboot instruction and run the same apply command again. The two ownership domains are in [Home Manager and system boundary](docs/system-boundary.md#windows-and-nixos-wsl).

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

Which machine gets which of these is the host registry, [Hosts and capabilities](docs/hosts.md).

## Links

- [Nix](https://nixos.org/)
- [Home Manager](https://github.com/nix-community/home-manager)
- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [nix-homebrew](https://github.com/zhaofengli/nix-homebrew)
- [Oh My Pi](https://github.com/can1357/oh-my-pi)
- [mise](https://mise.jdx.dev)
