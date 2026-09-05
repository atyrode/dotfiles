# Hosts and capabilities

`fleet/hosts.nix` is the authoritative registry for fixed machine identities.
A host entry contains stable, non-secret facts: its canonical configuration ID,
description, system, platform, activation owner, user, home directory, optional
hostname, selected capabilities, and optional declared Nix trusted-user
boundary.

Decision record: [ADR-0001](adr/0001-capability-based-host-composition.md).

`fleet/bootstrap-profiles.nix` defines account-portable Linux bootstrap profiles.
These contain system, platform, activation, description, and capabilities, but
never a username or home directory. `atyrode` validates the invoking non-root
account and materializes those identity fields locally for Home Manager.
`fleet/hosts.tsv` projects both bootstrap target kinds for `get.sh` before
Nix exists. NixOS and NixOS-WSL identities remain excluded from that Unix
picker, because a machine whose system is owned by this flake is installed and
updated by clan rather than picked by a bootstrap script; the registry check
keeps the projection honest.

Every registered host is a clan machine: `lib/configurations.nix` derives
clan's inventory from the registry, one machine per host with its class
(`darwin` or `nixos`) and the activation and platform as tags, and clan-core
builds its configuration ([ADR 0008](adr/0008-fleet-shape-and-substrate.md),
amended). Adding, renaming, or retiring a host is still a registry edit; clan
learns it from there, and the `host-registry` check asserts that clan names
exactly the registry's hosts. A machine's key and its registration with clan
are in [secrets.md](secrets.md).

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
- `security`: network diagnostics and `sops`, the reader of what activation
  decrypted and the crypto behind clan; the Mac additionally carries
  `age-plugin-se`, which holds the operator's daily identity in its Secure
  Enclave, and every clan machine carries the `clan` CLI
  ([secrets.md](secrets.md)). ClamAV is intentionally absent because no
  registered host owns signature updates or a scanning workflow.
- `server`: marks a Linux-only headless composition. The reviewed portable
  server selection combines it with `base` and `agent-tools`.

The same descriptions are semantic annotations in
`fleet/annotations.nix` (checked to cover the capability set exactly),
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

A NixOS machine this repository owns keeps its own hardware and network facts
in `fleet/machines/<host>/`: the disk layout disko writes, the boot loader, the
`systemd-networkd` configuration of its uplink, the `nixos-facter` report of
what the machine actually contains, and the address clan deploys to. Those
facts are public here on purpose. An address is not what protects a machine
that answers on the internet, resolves publicly, and is scanned continuously;
key-only SSH, no root login, and a firewall open on the ports it serves are,
and they are public here too. A machine that could not state its own address could not be
rebuilt from this repository, which is the test that matters
([invariant 8](../AGENTS.md)). The provider is a different kind of fact and
stays out of every file; `checks/lints/production-facts.nix` enforces both
halves of that rule. `dev-01`, the persistent development VPS, is the
first machine of this shape: `modules/nixos/vps.nix` is its policy — SSH plus
the web ports of exactly the vhosts `modules/nixos/manifold-dev-hub.nix`
and `modules/nixos/myparcelle-dev.nix` name (the Manifold preview tier and
parcel application fronts), with their upstreams bound to loopback,
declarative root-owned SSH keys drawn from the reviewed fleet key registry,
passwordless sudo for the operator's account alone, and rootless Docker — and
clan refuses to deploy it unless the operator names it.

The parcel development edge serves `myparcelle.tyrode.dev` from port 4173
and `auth.myparcelle.tyrode.dev` from port 8082. Caddy owns TLS; the
application checkout owns the development runtime and identity database.
Only the `myparcelle` realm and theme resources are public on the auth host:
Keycloak administration stays on loopback. Storybook is not published.
Source delivery does not authorize activation: any future activation needs
an independently reviewed service-disruption plan and the
[terminal-preservation safeguards](manifold.md#upgrades).

A client's production NixOS host is still not in this registry. Its
infrastructure flake supplies identity and system facts while importing the
same capability modules through the
[portable profile contract](portable-profiles.md). Such a consumer declares
`activation = "nixos"` and an exact non-secret `nixTrustedUsers` list including
`root`; `atyrode doctor system` then checks the NixOS login-shell path and that
host-specific daemon trust boundary instead of the Home Manager-only Linux
defaults a portable profile gets.
`wsl` is a deliberate local-workstation exception: this flake
exports its complete `nixosConfigurations` entry and owns that WSL guest, while
native Windows packages and state retain their separate WinGet/application
boundary. The full Home Manager, nix-darwin, NixOS-WSL, and Windows ownership
model is documented in [Home Manager and system boundary](system-boundary.md).

## Adding a target

For a fixed machine identity:

1. Add one canonical entry to `fleet/hosts.nix`.
2. Declare a supported `system`, matching `platform`, supported `activation`
   owner, non-empty `username`, absolute `homeDirectory`, a non-empty one-line
   `description`, and at least one valid capability. A `nixos-wsl` host also
   requires a stable hostname. A `nixos` host must declare a unique, non-empty
   `nixTrustedUsers` list containing `root`, and its hardware and network facts
   go in `fleet/machines/<host>/`.

For a portable Linux bootstrap profile:

1. Add an architecture-specific entry to `fleet/bootstrap-profiles.nix`.
2. Declare Linux, Home Manager activation, a description, and capabilities.
   Do not declare account or machine identity.

Then add or reuse capability modules under `modules/home/profiles/`; do not put
target-specific packages in either registry. Regenerate `fleet/hosts.tsv`
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

On the first apply after a fixed host's ID or hostname changes, name the new
host explicitly: `atyrode apply <new-host>`. A generated `host.json` that still
names the removed ID is ignored during automatic detection. An explicit target
may replace an unregistered former hostname, and the apply prints the hostname
the switch will install; it still refuses when the current hostname belongs to
a different registered machine.

For retirement, first remove callers and machine state that select the host,
then remove its canonical registry entry. Never reuse an old host ID for a
different machine or security boundary. Mutable sessions, credentials, trust
state, and secrets are not registry data and require their own retirement
procedure.
