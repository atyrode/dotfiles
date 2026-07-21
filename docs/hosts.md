# Hosts and capabilities

`hosts/default.nix` is the authoritative registry for supported dotfiles
configurations. A host entry contains stable, non-secret facts: its canonical
configuration ID, a one-line description, system, platform, activation owner,
user, home directory, optional hostname, and selected capabilities. The
macOS/Linux bootstrap-eligible hosts are offered by `get.sh` through the
committed `inventory/hosts.tsv` projection before Nix exists. NixOS-WSL is
intentionally excluded from that Unix picker and enters through `get.ps1`; the
host-registry check keeps both contracts honest.

Capabilities are declarative Home Manager modules, not imperative `nix
profile` state. Home Manager generations remain activation history and rollback
points; OMP profiles and Codex's `~/.codex` remain harness-specific mutable-state boundaries.

## Current capabilities

- `base`: shell, Git/GitHub, search, direnv/nix-direnv, mise, on-demand lookup,
  diagnostics, and Home Manager itself.
- `development`: cross-repository Nix and shell quality tools, not project
  language runtimes.
- `agent-tools`: Codex, OMP, Orca, managed agents, and their configuration.
- `desktop`: operator-selected graphical applications.
- `mobile`: Android device tooling.
- `media`: audio/video conversion and inspection.
- `containers`: container clients and inspection tools; the daemon is
  system-owned.
- `security`: network diagnostics. ClamAV is intentionally absent because no
  registered host owns signature updates or a scanning workflow.
- `server`: marks a Linux-only headless composition. The reviewed portable
  server selection combines it with `base` and `agent-tools`.

The same descriptions are semantic annotations in
`inventory/annotations.nix` (checked to cover the capability set exactly),
surface in `atyrode capabilities list` — which marks the resolved host's active
capabilities — and in `atyrode capabilities show`, and export to flake consumers
as `lib.capabilityDescriptions`. Evaluated package membership is available
separately through `capabilityInventory.<system>.<capability>`.
Adding a capability to a machine is a registry edit: extend the host's
`capabilities` list, merge, and run
`atyrode apply` on that machine.

Project compilers and runtimes are owned by committed dev shells, `mise.toml`,
and native manifests. See [Package ownership](package-ownership.md) for the
checked evaluated inventory and harness boundaries.

Each activated Home Manager configuration exposes its canonical identity in
`$ATYRODE_HOST`, its comma-separated capability set in
`$ATYRODE_CAPABILITIES`, and a non-secret JSON projection at
`~/.config/atyrode/host.json`. The same pure projection is available to flake
consumers as `lib.hostRegistry`; `lib.capabilities` lists valid capability
names.

External production NixOS hosts do not belong in this registry. Their
infrastructure flake supplies identity and system facts while importing the same
capability modules through the [portable profile contract](portable-profiles.md).
`alex-x86_64-linux-wsl` is a deliberate local-workstation exception: this flake
exports its complete `nixosConfigurations` entry and owns that WSL guest, while
native Windows packages and state retain their separate WinGet/application
boundary. The full Home Manager, nix-darwin, NixOS-WSL, and Windows ownership
model is documented in [Home Manager and system boundary](system-boundary.md).

## Adding a host

1. Add one canonical entry to `hosts/default.nix`.
2. Declare a supported `system`, matching `platform`, supported `activation`
   owner, non-empty `username`, absolute `homeDirectory`, a non-empty one-line
   `description`, and at least one valid capability. A `nixos-wsl` host also
   requires a stable hostname.
3. Add or reuse capability modules under `home/profiles/`; do not put
   host-specific packages directly in the registry.
4. Regenerate `inventory/hosts.tsv` for bootstrap-eligible non-WSL entries
   (the host-registry check diffs it against that filtered projection).
5. Run `nix flake check --all-systems --no-build --show-trace`. The aggregate
   Home Manager, nix-darwin, and NixOS-WSL checks evaluate every canonical host
   on its native system.

Registry evaluation refuses unsupported systems or activation owners, platform
mismatches, empty users, relative home directories, missing WSL hostnames,
missing base capabilities, server/desktop or server/development conflicts,
non-Linux server selections, and duplicate or unknown capabilities. Portable
consumers may omit `description`; for this repository's own registry the
host-registry check requires it non-empty.

## Renaming or retiring a host

Host IDs are canonical and have no aliases. A rename is a clean cutover: update
active-configuration state and automation, then replace the registry key. Do
not leave the former name as a forwarding configuration.

For retirement, first remove callers and machine state that select the host,
then remove its canonical registry entry. Never reuse an old host ID for a
different machine or security boundary. Mutable sessions, credentials, trust
state, and secrets are not registry data and require their own retirement
procedure.
