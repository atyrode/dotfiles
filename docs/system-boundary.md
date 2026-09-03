# Home Manager and system boundary

Home Manager owns the portable user environment in this repository. It can
install a client or shell and configure files below the user's home directory,
whether standalone or integrated into nix-darwin/NixOS. It cannot make a native
account database, daemon, device rule, privileged group, or package manager
operational. Those prerequisites belong to the corresponding system layer and
are checked separately.

Decision record: [ADR-0002](adr/0002-home-manager-primary-authority.md).

## Ownership matrix

| Concern | Standalone Home Manager on Linux | Home Manager through nix-darwin | Home Manager imported by NixOS |
|---|---|---|---|
| User packages and dotfiles | Home Manager | Home Manager | Home Manager |
| Zsh startup, Git, CLI and agent configuration | Home Manager | Home Manager | Home Manager |
| Home Manager generations | Home Manager | Home Manager inside the Darwin generation | Home Manager inside the NixOS generation |
| Account and login-shell selection | `atyrode apply` registers `$HOME/.nix-profile/bin/zsh` in `/etc/shells` and selects it with `chsh` using explicit privilege, reconverging after every activation | nix-darwin registers Zsh and sets the existing primary user's `UserShell` to `/run/current-system/sw/bin/zsh` during activation | The consuming infrastructure enables Zsh and sets `users.users.<name>.shell` |
| `sudo` authentication | Operating system/operator | nix-darwin manages `/etc/pam.d/sudo_local`, enabling Touch ID with password fallback and reattachment for tmux sessions | The consuming infrastructure |
| Nix daemon, store and service lifecycle | The system-wide Nix installation | nix-darwin | The consuming NixOS infrastructure |
| Nix trust, cache and optimisation policy | System Nix configuration; never a Home Manager `nix.conf` override. Bootstrap enrols the fleet cache in `/etc/nix/nix.conf` once; `doctor` names the line when it is missing | nix-darwin | The consuming NixOS infrastructure |
| Container engine and privileged access | System/operator, using a rootless per-user engine | OrbStack runtime state, outside Home Manager | The consuming infrastructure |
| Android device access | System-owned udev policy | macOS per-device USB authorization | The consuming infrastructure's udev policy |
| Antivirus signatures and scanning | Unmanaged; ClamAV is intentionally absent | Unmanaged; ClamAV is intentionally absent | An infrastructure concern if the host elects to provide it |
| Homebrew installation and declared casks | Not applicable | nix-homebrew and nix-darwin; Homebrew retains native mutable state | Not applicable |
| Filesystems, networking, firewall, SSH, services, logging, updates, monitoring, backups and secrets | Operating system/operator | Operating system and nix-darwin where declared | The consuming infrastructure |

## Windows and NixOS-WSL

The home Windows machine deliberately has two ownership domains:

- NixOS-WSL owns the Linux guest, its system generation, the `alex` account,
  integrated Home Manager profile, and WSL interoperability settings.
- Native Windows remains outside Nix. `fleet/windows-packages.nix` is a reviewed
  package declaration consumed by `atyrode windows plan/apply`; the controller
  invokes the existing `winget.exe` as the interactive Windows user to
  reconcile the declared exact package IDs.

`get.ps1` is the one native bootstrap boundary. Its default action is a
non-mutating plan. Apply verifies a pinned NixOS-WSL image, refuses to reuse an
unmarked distribution or non-empty install location, activates an exact Git
revision, and only then starts native package reconciliation. The activation
marker at `/etc/atyrode/wsl-host.json` distinguishes the managed distribution
from an unrelated WSL instance.

The two apply phases are intentionally explicit rather than pretending to be
one transaction. Nix generations can roll back the WSL guest; they cannot roll
back WinGet. A failed Windows phase therefore reports the exact
`atyrode windows plan` / `atyrode windows apply` recovery path. Reconciliation
installs reviewed exact package IDs, but does not silently uninstall a
conflicting Zen channel.

Windows application accounts, profiles, update services, caches, and other
mutable state remain application-owned. In particular, Zen's Mozilla account,
sync tokens, cookies, sessions, and browser profile never enter the Nix store
or repository; Mozilla sign-in remains an interactive step on each device.

For external production NixOS hosts, the relationship remains one-way:
infrastructure pins this flake and imports its Home Manager profiles. It passes
the non-secret machine identity with `activation = "nixos"` and an exact
`nixTrustedUsers` list, while retaining ownership of those daemon settings.
Dotfiles do not acquire production identity, disks, services, or secrets. The
repository-owned `alex-x86_64-linux-wsl` configuration is the deliberate
workstation exception: it owns only the local WSL guest and imports the same
portable profiles. See [Portable Home Manager profiles](portable-profiles.md).

Starting the managed distribution while another WSL distribution is already
running can leave the guest without a systemd user session (`wsl: Failed to
start the systemd user session`, and `systemctl --user` cannot reach the user
bus). This is an upstream WSL defect rather than managed state:
[NixOS-WSL #888](https://github.com/nix-community/NixOS-WSL/issues/888) tracks
it against
[microsoft/WSL #13188](https://github.com/microsoft/WSL/issues/13188). Interop
commands, `atyrode doctor`, and Windows reconciliation still work without the
user session. Recovery is `wsl --shutdown` followed by starting
`atyrode-nixos` first; keep other distributions free of logon autostart
launchers so the managed guest boots alone.

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

Antivirus signature updates, scheduled scans, quarantine, and alert handling
are system-owned; no managed host declares that policy, so ClamAV binaries must
be absent.

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
| `nix-policy` | Trusted users match the exact host contract (`root` for standalone hosts; the declared list for integrated NixOS), the substituters are exactly the official cache followed by the fleet cache with exactly their two signing keys trusted, signatures are required, and the nix-darwin optimiser is scheduled on macOS. |
| `container-engine` | The selected container engine is reachable without Docker-group membership, or the capability is not selected. |
| `antivirus-data` | Verifies ClamAV binaries are absent while no host owns signatures/scanning; an unmanaged binary is drift. |
| `device-permissions` | Android access policy is ready, or the `mobile` capability is not selected. |
| `homebrew-drift` | The generated nix-darwin Brewfile matches Homebrew state, or Homebrew does not apply. |
| `bootstrap-residue` | macOS carries none of the states `bootstrap/install.sh` repairs before Nix exists: an unrestored `.backup-before-nix` shell rc, an `/etc` profile file where nix-darwin owns a link, an `/etc` link into a store path that is gone, a TLS anchor Nix cannot read, an `fstab` line mounting `/nix` from a volume that no longer resolves. Not applicable off macOS. |

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
check` plus generated `brew bundle cleanup` with standard input closed and
without `--force` or `--zap`; it reports drift without offering the
activation-only reconciliation prompt.

## Login-shell convergence

Home Manager owns Zsh configuration but not the account's login-shell field.
Which layer closes that gap is exactly what the `login-shell` row reports as
its `owner`:

- On standalone Linux the owner is `atyrode`. After a successful Home Manager
  activation, `atyrode apply` verifies `$HOME/.nix-profile/bin/zsh`, registers
  it in `/etc/shells`, and selects it with `chsh` using explicit root or
  `sudo` privilege — each step only where the state is actually wrong — then
  reads the account database back. It never treats the inherited `$SHELL`
  environment variable as proof.
- Through nix-darwin the owner is nix-darwin. It declares the system Zsh path
  and updates only the already-existing primary user's `UserShell`. Activation
  refuses to invent a missing user.
- Under NixOS the owner is the consuming infrastructure, which owns both
  `programs.zsh.enable` and the user's system shell.

The field is re-derived on every apply rather than closed once, so an account
whose login shell is changed out from under the configuration is corrected by
the next apply with no separate command and no state to repair first.

Where `atyrode` owns the field and cannot converge it — no `chsh`, no
privilege to run it, an account database that does not read back — the
already-successful Home Manager activation stays complete rather than being
rolled back or relabelled as failed. Apply prints the reason it could not
converge and exits `69`. Where another layer owns the field, a mismatch is a
warning instead: rerunning apply cannot fix somebody else's activation, so
failing on it would only make a correct Home Manager generation look broken.

## Platform policy details

The reviewed Nix policy is deliberately narrow: the daemon store is
system-owned, standalone hosts trust exactly `root`, integrated NixOS hosts
trust exactly their declared non-secret `nixTrustedUsers`, the configured
binary caches are exactly the official Nix cache followed by the fleet cache
with their two signing keys, and signatures are required. nix-darwin also
schedules store optimisation. Linux Home Manager does not pretend to own
those settings; standalone Linux repairs belong to the system Nix
installation, and NixOS repairs belong to the consuming infrastructure.

### The fleet cache

CI is the fleet's only builder: every host closure is built on push, signed,
and copied to a binary cache that every machine reads second, after the
official cache, so an apply anywhere is a download of what CI already
verified. From a green `main` it publishes everything the run compiled, not
only the finished closures and not only on Linux: the derivations behind the
checks, and the Mac's closure too. The consumer that made this worth doing is
CI itself. Every pull request used to rebuild every check on three platforms
from an empty store, which was most of the time a change spent waiting;
publishing the intermediate work means a pull request builds what it changed
and downloads the rest. `fleet/system-boundary.json` is the one place the
cache's read URL and public signing key are written;
`modules/shared/binary-caches.nix` derives
the two ordered lists from it for nix-darwin and NixOS-WSL, and the
system-boundary check and `doctor` assert the same lists from the same file,
so none of the four can drift from the others.

The cache is public-read on purpose. This flake is public and nothing secret
ever enters the Nix store, so a closure in the cache reveals nothing a clone
of the repository does not; the read path carries no credential, which is
what lets an unattended machine — or a fork's CI — fetch from it without
holding one. Integrity does not rest on the transport: the private signing
key exists only in CI, every machine requires signatures, and a path signed
by neither trusted key is rejected wherever it came from. Write access is a
separate credential held only by CI.

Who writes the setting follows the ownership matrix. nix-darwin and
NixOS-WSL declare both caches in their system configuration. Standalone Linux
has no such layer: its daemon trusts only `root`, so a key in a user
`nix.conf` is a restricted setting the daemon ignores, and the fleet key has
to be in `/etc/nix/nix.conf`, the file the daemon reads. Bootstrap appends
it there on a new machine, and on an existing one `doctor`'s `nix-policy`
remediation is the exact privileged line that does the same — two `extra-`
settings, so the official entries are never restated, followed by the daemon
restart it needs to read them.

On macOS, nix-darwin owns the immutable list of Homebrew taps and casks.
Activation runs Homebrew Bundle with forced cleanup and zap: undeclared taps,
formulae, and casks are uninstalled and their support files purged, so
retiring a declaration removes the software from the machine on the next
apply with no bespoke removal code. Zap is deliberately data-destructive for
undeclared casks; native state worth keeping must be declared. Automatic
update and upgrade remain disabled, and Homebrew's cellar and application
state remain native mutable state rather than Nix store content.
