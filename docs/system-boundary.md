# Home Manager and system boundary

Home Manager owns the portable user environment in this repository. It can
install a client or shell and configure files below the user's home directory;
it cannot make an account database, daemon, device rule, privileged group, or
native package manager operational. Those prerequisites belong to the system
layer and are checked separately.

## Ownership matrix

| Concern | Standalone Home Manager on Linux | Home Manager through nix-darwin | Home Manager imported by NixOS |
|---|---|---|---|
| User packages and dotfiles | Home Manager | Home Manager | Home Manager |
| Zsh startup, Git, CLI and agent configuration | Home Manager | Home Manager | Home Manager |
| Home Manager generations | Home Manager | Home Manager inside the Darwin generation | Home Manager inside the NixOS generation |
| Account and login-shell selection | Bootstrap registers `$HOME/.nix-profile/bin/zsh` in `/etc/shells` and selects it with `chsh` using explicit privilege | nix-darwin registers Zsh and sets the existing primary user's `UserShell` to `/run/current-system/sw/bin/zsh` during activation | The consuming infrastructure enables Zsh and sets `users.users.<name>.shell` |
| `sudo` authentication | Operating system/operator | nix-darwin manages `/etc/pam.d/sudo_local`, enabling Touch ID with password fallback and reattachment for tmux sessions | The consuming infrastructure |
| Nix daemon, store and service lifecycle | The system-wide Nix installation | nix-darwin | The consuming NixOS infrastructure |
| Nix trust, cache and optimisation policy | System Nix configuration; never a Home Manager `nix.conf` override | nix-darwin | The consuming NixOS infrastructure |
| Container engine and privileged access | System/operator, using a rootless per-user engine | OrbStack runtime state, outside Home Manager | The consuming infrastructure |
| Android device access | System-owned udev policy | macOS per-device USB authorization | The consuming infrastructure's udev policy |
| Antivirus signatures and scanning | Unmanaged; ClamAV is intentionally absent | Unmanaged; ClamAV is intentionally absent | An infrastructure concern if the host elects to provide it |
| Homebrew installation and declared casks | Not applicable | nix-homebrew and nix-darwin; Homebrew retains native mutable state | Not applicable |
| Filesystems, networking, firewall, SSH, services, logging, updates, monitoring, backups and secrets | Operating system/operator | Operating system and nix-darwin where declared | The consuming infrastructure |

The NixOS relationship is one-way: infrastructure pins this flake and imports
its Home Manager profiles. Dotfiles do not import infrastructure or acquire
production identity, disks, services, or secrets. See [Portable Home Manager
profiles](portable-profiles.md).

## Installed is not operational

Package presence proves only that a program can be invoked. Operational
readiness also depends on state that Home Manager must not silently create:

- Zsh can be installed while the real account database still selects Bash, or
  while the managed path is missing from `/etc/shells`.
- The Docker client can be installed while no engine is reachable. On Linux,
  readiness means a rootless engine at `/run/user/<uid>/docker.sock`; membership
  in the root-equivalent `docker` group is forbidden. On macOS, readiness means
  the explicit `orbstack` Docker context is available.
- `adb` can be installed while Linux USB access has no suitable udev rule.
  Readiness requires an Android/ADB-identified vendor rule using `uaccess`, or
  a reviewed `adbusers` or `plugdev` group rule whose group the user actually
  belongs to. On macOS the
  check proves ADB is installed; macOS still grants device authorization at
  connection time, so it does not claim that a particular device is trusted.
- The Nix CLI can run while the daemon is unreachable or its effective trust
  and cache settings differ from policy.
- Declared Homebrew casks can be present while additional, undeclared Homebrew
  state has drifted outside the generated Brewfile.

ClamAV was removed rather than treated as ready merely because its executable
was installed. No registered host owns signature updates, scheduled scans,
quarantine, or alert handling. The `security` capability therefore provides
network diagnostics (`nmap` and `socat`), not an implied antivirus service.
The doctor only checks for binary presence; it never executes ClamAV or updates
signatures. A leftover binary is `incomplete` unmanaged drift until removed or
backed by a separately reviewed system policy.

## System diagnostics

Run the read-only readiness audit for the active host, or name a registered
host explicitly:

```sh
atyrode doctor system
atyrode doctor system alex-x86_64-linux-desktop
atyrode doctor system alex-aarch64-darwin --json
```

The checks always appear in this order:

| Check ID | What it establishes |
|---|---|
| `login-shell` | The real account database selects the expected executable Zsh path and that path is listed as an allowed shell. |
| `nix-daemon` | The system-owned daemon store is reachable. |
| `nix-policy` | Trusted users are exactly `root`, only the official signed cache and key are configured, signatures are required, and the nix-darwin optimiser is scheduled on macOS. |
| `container-engine` | The selected container engine is reachable without Docker-group membership, or the capability is not selected. |
| `antivirus-data` | Verifies ClamAV binaries are absent while no host owns signatures/scanning; an unmanaged binary is drift. |
| `device-permissions` | Android access policy is ready, or the `mobile` capability is not selected. |
| `homebrew-drift` | The generated nix-darwin Brewfile matches Homebrew state, or Homebrew does not apply. |

Each row has a stable `id`, `owner`, `required`, `status`, `code`, `summary`,
`remediation`, `expected`, and `actual` shape. Status is one of:

- `ok`: the applicable readiness contract is satisfied;
- `incomplete`: installed capability or required system policy is not ready;
- `not-applicable`: the platform/capability does not require the check, or a
  deliberately unmanaged feature such as antivirus is being recorded.

JSON output has `schemaVersion: 1`, the canonical host, platform, system,
capabilities, ordered `checks`, an aggregate `ok`, and
`mutationBoundary: "read-only probes"`. It reports booleans and policy results
instead of raw Nix configuration values, so cache URLs containing credentials
cannot leak through the diagnostic.

The command exits `0` when no check is incomplete, `69` when remediation is
needed, `64` for invalid invocation, and `65` for an unknown or mismatched host
identity. Internal policy/schema failures use `70`.

Diagnostics do not start or restart services, change shells or groups, install
udev rules, update antivirus data, start ADB, or remove Homebrew packages. In
particular, the Android probe does not run `adb devices`, which could start a
daemon and create authentication state. The Homebrew probe runs `brew bundle
check` plus generated `brew bundle cleanup` in check mode, with standard input
closed and without `--force` or `--zap`; missing and extra state must be
reviewed and either declared or removed manually.

## Login-shell activation and recovery

Home Manager owns Zsh configuration but not the account's login-shell field.
The bootstrap closes that prerequisite after a successful Home Manager
transaction:

- Linux verifies `$HOME/.nix-profile/bin/zsh`, adds it to `/etc/shells` once,
  uses explicit root or `sudo` privilege for `chsh`, and then reads the account
  database back. It never treats the inherited `$SHELL` environment variable
  as proof.
- nix-darwin declares the system Zsh path and updates only the already-existing
  primary user's `UserShell`. Activation refuses to invent a missing user.
- NixOS consumers own both `programs.zsh.enable` and the user's system shell in
  their infrastructure configuration.

If this final prerequisite fails, the already-successful Home Manager
activation remains complete. Bootstrap returns `69` and writes
`${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/login-shell.incomplete`
as a recoverable, non-secret marker; it does not mislabel the activation as
failed or roll it back. Repair the reported system prerequisite and run
`./install.sh verify --config <host>`, or rerun `apply` with the needed
privilege. Successful verification removes the marker.

## Platform policy details

The reviewed Nix policy is deliberately narrow: the daemon store is
system-owned, trusted users are exactly `root`, the official Nix cache and its
official signing key are the only configured binary cache, and signatures are
required. nix-darwin also schedules store optimisation. Linux Home Manager
does not pretend to own those settings; standalone Linux repairs belong to the
system Nix installation, and NixOS repairs belong to the consuming
infrastructure.

On macOS, nix-darwin owns the immutable list of Homebrew taps and casks and
uses `cleanup = "check"` with automatic update and upgrade disabled. This
makes drift visible without automatically uninstalling operator-owned software.
Homebrew's cellar and application state remain native mutable state rather than
Nix store content.
