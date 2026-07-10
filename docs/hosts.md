# Hosts and capabilities

`hosts/default.nix` is the authoritative registry for supported dotfiles
configurations. A host entry contains stable, non-secret facts: its canonical
configuration ID, system, platform, user, home directory, optional hostname,
compatibility aliases, and selected capabilities.

Capabilities are declarative Home Manager modules, not imperative `nix
profile` state. Home Manager generations remain activation history and rollback
points; OMP and Codex profiles remain harness-specific mutable-state boundaries.

## Current capabilities

- `base`: shell, Git, mise, and Home Manager itself.
- `development`: the current shared CLI and development package set.
- `agent-tools`: Codex, OMP, Herdr, managed agents, and their configuration.
- `desktop`: desktop-only additions; currently selects the Linux desktop module.
- `server`: marks the reviewed headless composition consumed by #28.

Issue #18 owns the next package-placement pass. Until it lands, some packages
inside `development` remain broader than their eventual mobile, media,
container, security, or project-owned capabilities. The registry records the
composition boundary now without claiming that package classification is
already complete.

Each activated Home Manager configuration exposes its canonical identity in
`$ATYRODE_HOST`, its comma-separated capability set in
`$ATYRODE_CAPABILITIES`, and a non-secret JSON projection at
`~/.config/atyrode/host.json`. The same pure projection is available to flake
consumers as `lib.hostRegistry`; `lib.capabilities` lists valid capability
names.

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
conflicts, duplicate or unknown capabilities, duplicate aliases, and aliases
that collide with canonical host IDs.

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
