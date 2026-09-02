# Hosts and capabilities

`hosts/default.nix` is the authoritative registry for fixed machine identities.
A host entry contains stable, non-secret facts: its canonical configuration ID,
description, system, platform, activation owner, user, home directory, optional
hostname, selected capabilities, and optional declared Nix trusted-user
boundary.

Decision record: [ADR-0001](adr/0001-capability-based-host-composition.md).

`hosts/bootstrap.nix` defines account-portable Linux bootstrap profiles.
These contain system, platform, activation, description, and capabilities, but
never a username or home directory. `atyrode` validates the invoking non-root
account and materializes those identity fields locally for Home Manager.
`inventory/hosts.tsv` projects both bootstrap target kinds for `get.sh` before
Nix exists. Infrastructure-owned NixOS and repository-owned NixOS-WSL identities
remain excluded from that Unix picker; the registry check keeps the projection
honest.

Capabilities are declarative Home Manager modules, not imperative `nix
profile` state. Home Manager generations remain activation history and rollback
points; OMP profiles and Codex's `~/.codex` remain harness-specific mutable-state boundaries.

## Current capabilities

- `base`: shell, Git/GitHub, search, direnv/nix-direnv, mise, on-demand lookup,
  diagnostics, and Home Manager itself.
- `development`: cross-repository Nix, shell, and workflow quality tools, not
  project language runtimes.
- `agent-tools`: Codex, OMP, managed agents, and their configuration.
- `desktop`: operator-selected graphical applications.
- `mobile`: Android device tooling.
- `media`: audio/video conversion and inspection.
- `containers`: container clients and inspection tools; the daemon is
  system-owned.
- `security`: network diagnostics and `sops`, the editor and reader of the
  fleet's secrets; the Mac additionally carries `age-plugin-se`, which holds
  the operator's daily identity in its Secure Enclave ([secrets.md](secrets.md)).
  ClamAV is intentionally absent because no registered host owns signature
  updates or a scanning workflow.
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

Each activated Home Manager configuration exposes its target identity in
`$ATYRODE_HOST`, its comma-separated capability set in
`$ATYRODE_CAPABILITIES`, and a non-secret JSON projection at
`~/.config/atyrode/host.json`. Fixed identities are available to flake consumers
as `lib.hostRegistry`; account-portable profiles are in
`lib.bootstrapProfiles`; `lib.targetRegistry` combines both.
`lib.capabilities` lists valid capability names.

External production NixOS hosts do not belong in this standalone registry.
Their infrastructure flake supplies identity and system facts while importing
the same capability modules through the
[portable profile contract](portable-profiles.md). Such a consumer declares
`activation = "nixos"` and an exact non-secret `nixTrustedUsers` list including
`root`; `atyrode doctor system` then checks the NixOS login-shell path and that
host-specific daemon trust boundary instead of applying standalone Linux
defaults.
`alex-x86_64-linux-wsl` is a deliberate local-workstation exception: this flake
exports its complete `nixosConfigurations` entry and owns that WSL guest, while
native Windows packages and state retain their separate WinGet/application
boundary. The full Home Manager, nix-darwin, NixOS-WSL, and Windows ownership
model is documented in [Home Manager and system boundary](system-boundary.md).

## Adding a target

For a fixed machine identity:

1. Add one canonical entry to `hosts/default.nix`.
2. Declare a supported `system`, matching `platform`, supported `activation`
   owner, non-empty `username`, absolute `homeDirectory`, a non-empty one-line
   `description`, and at least one valid capability. A `nixos-wsl` host also
   requires a stable hostname. An infrastructure-supplied `nixos` identity must
   declare a unique, non-empty `nixTrustedUsers` list containing `root`.

For a portable Linux bootstrap profile:

1. Add an architecture-specific entry to `hosts/bootstrap.nix`.
2. Declare Linux, Home Manager activation, a description, and capabilities.
   Do not declare account or machine identity.

Then add or reuse capability modules under `home/profiles/`; do not put
target-specific packages in either registry. Regenerate `inventory/hosts.tsv`
for bootstrap-eligible entries, then run
`nix flake check --all-systems --no-build --show-trace`. The aggregate checks
evaluate fixed targets and instantiate every portable profile for multiple
account identities.

Registry evaluation refuses unsupported systems or activation owners, platform
mismatches, invalid fixed identities, account fields on runtime profiles,
missing WSL hostnames, invalid NixOS trust boundaries, missing base
capabilities, server/desktop or server/development conflicts, non-Linux server
selections, and duplicate or unknown capabilities. Every repository-owned
target requires a non-empty description.

## Renaming or retiring a host

Host IDs are canonical and have no aliases. A rename is a clean cutover: update
active-configuration state and automation, then replace the registry key. Do
not leave the former name as a forwarding configuration.

For retirement, first remove callers and machine state that select the host,
then remove its canonical registry entry. Never reuse an old host ID for a
different machine or security boundary. Mutable sessions, credentials, trust
state, and secrets are not registry data and require their own retirement
procedure.
