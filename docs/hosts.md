# Hosts and capabilities

`hosts/default.nix` is the authoritative registry for supported dotfiles
configurations. A host entry contains stable, non-secret facts: its canonical
configuration ID, system, platform, user, home directory, optional hostname,
compatibility aliases, and selected capabilities.

Capabilities are declarative Home Manager modules, not imperative `nix
profile` state. Home Manager generations remain activation history and rollback
points; OMP and Codex profiles remain harness-specific mutable-state boundaries.

## Current capabilities

- `base`: shell, Git/GitHub, search, direnv/nix-direnv, mise, on-demand lookup,
  diagnostics, and Home Manager itself.
- `development`: cross-repository Nix and shell quality tools, not project
  language runtimes.
- `agent-tools`: Codex, OMP, Herdr, managed agents, and their configuration.
- `desktop`: operator-selected graphical applications.
- `mobile`: Android device tooling.
- `media`: audio/video conversion and inspection.
- `containers`: container clients and inspection tools; the daemon is
  system-owned.
- `security`: declared scanning and network diagnostics.
- `server`: marks a Linux-only headless composition. The reviewed portable
  server selection combines it with `base` and `agent-tools`.

Project compilers and runtimes are owned by committed dev shells, `mise.toml`,
and native manifests. See [Package ownership](package-ownership.md) for the
checked matrix and harness boundaries.

Each activated Home Manager configuration exposes its canonical identity in
`$ATYRODE_HOST`, its comma-separated capability set in
`$ATYRODE_CAPABILITIES`, and a non-secret JSON projection at
`~/.config/atyrode/host.json`. The same pure projection is available to flake
consumers as `lib.hostRegistry`; `lib.capabilities` lists valid capability
names.

Production NixOS hosts do not belong in this registry. Their infrastructure
flake supplies identity and system facts while importing the same capability
modules through the [portable profile contract](portable-profiles.md).

## Adding a host

1. Add one canonical entry to `hosts/default.nix`.
2. Declare a supported `system`, matching `platform`, non-empty `username`,
   absolute `homeDirectory`, and at least one valid capability.
3. Add only compatibility names that must remain accepted to `aliases`.
4. Add or reuse capability modules under `home/profiles/`; do not put
   host-specific packages directly in the registry.
5. Run `nix flake check --all-systems --no-build --show-trace`. The aggregate
   home and Darwin checks evaluate every canonical host on its native system.

Registry evaluation refuses unsupported systems, platform mismatches, empty
users, relative home directories, missing base capabilities, server/desktop
or server/development conflicts, non-Linux server selections, duplicate or
unknown capabilities, duplicate aliases, and aliases that collide with
canonical host IDs.

## Renaming or retiring a host

For a rename, create the new canonical entry and keep the former public name as
an alias for a documented compatibility period. Aliases resolve to the new
canonical configuration, so diagnostics and the generated JSON report the new
identity. Remove the alias only after active-configuration state and automation
no longer reference it.

For retirement, first remove callers and machine state that select the host,
then remove its canonical registry entry and aliases together. Never reuse an
old host ID for a different machine or security boundary. Mutable sessions,
credentials, trust state, and secrets are not registry data and require their
own retirement procedure.
