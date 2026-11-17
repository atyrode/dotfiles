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

The same descriptions are one sentence each in `fleet/capabilities.nix`
(checked to cover the capability set exactly), surface in
`atyrode capabilities list` — which marks the resolved host's active
capabilities — and in `atyrode capabilities show`, and export to flake consumers
as `lib.capabilityDescriptions`. Adding a capability to a machine is a registry
edit: extend the host's `capabilities` list, merge, and run `atyrode apply` on
that machine.

Project compilers and runtimes are owned by committed dev shells, `mise.toml`,
and native manifests; `checks/fleet/system-boundary.nix` holds the package
assertions each capability must satisfy.

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
and they are public here too. Declared hardware and network configuration
supports rebuilding from this repository and its locked inputs
([source boundary](../AGENTS.md#boundaries)); it is not proof of a timed recovery.
The provider is a different kind of fact and
stays out of every file; `checks/lints/production-facts.nix` enforces both
halves of that rule. `dev-01`, the persistent development VPS, is the
first machine of this shape: `modules/nixos/vps.nix` is its policy — SSH plus
the web ports of exactly the vhosts `modules/nixos/manifold-dev-hub.nix`,
`modules/nixos/myparcelle-dev.nix`, `modules/nixos/games.nix`,
`modules/nixos/kroissant-dev.nix`, `modules/nixos/house-studio-dev.nix`, and
`modules/nixos/parxel-dev.nix` name (the Manifold preview tier, parcel fronts,
games, the kroissant site's development stack, the house studio, and the
parxel design preview), with upstreams bound to loopback,
declarative root-owned SSH keys drawn from the reviewed fleet key registry,
passwordless sudo for the operator's account alone, and rootless Docker — and
clan refuses to deploy it unless the operator names it.

The parcel development edge serves `myparcelle.tyrode.dev` from port 4173
and `auth.myparcelle.tyrode.dev` from port 8082. Caddy owns TLS; the
application checkout owns the development runtime and identity database.
Only the `myparcelle` realm and theme resources are public on the auth host:
Keycloak administration stays on loopback. The application edge adds nothing
but TLS and compression: caching and the admin gate on `/storybook/` are the
application's, exactly as on production, so a reviewer sees on the
development surface what production would show.
Its pull-request previews are `pr-<n>.preview.myparcelle.tyrode.dev`, one
wildcard vhost forwarded whole to the loopback router on port 4300 that
myParcelle's `scripts/preview/` tooling generates as previews come and go
(its `deploy/README.md` § Pull-request previews).
Their certificates are issued on demand like the Manifold tier's. Caddy's
on-demand permission is one global `ask` endpoint, so
[`modules/nixos/caddy-on-demand-ask.nix`](../modules/nixos/caddy-on-demand-ask.nix)
owns it: a loopback dispatcher on 7899 forwards each question to the router
of the zone that owns the name, one label deep, and refuses everything else.
A tier registers its zone there instead of setting `on_demand_tls` itself;
`nix build .#checks.x86_64-linux.caddy-on-demand-ask` exercises the deployed
dispatcher through real Caddy. The extra `preview.` label keeps the wildcard
off `auth.myparcelle.tyrode.dev`, whose managed certificate a covering
wildcard site would suppress.
Source delivery does not authorize activation: any future activation needs
an independently reviewed service-disruption plan and the
[terminal-preservation safeguards](manifold.md#upgrades).

myParcelle's CI also runs here:
[`modules/nixos/myparcelle-ci-runners.nix`](../modules/nixos/myparcelle-ci-runners.nix)
declares five ephemeral self-hosted GitHub Actions runners (labels
`self-hosted`, `linux`, `x64`, `dev-01`; the first three also `pull-request`,
which myParcelle's pull-request jobs require, so the last two stay free for
its merge queue) under the `myparcelle-ci` system
account and its own rootless Docker engine. Each job runs in a fresh
Docker-in-Docker engine and runner container pair, capped per job and as a
whole slice, and deleted when the job ends; each start mints a single-use
runner configuration from a root-only token the operator places at
`/var/lib/myparcelle-ci-runners/github-token` (a fine-grained token on that
one repository, Administration: write). Until the file exists the runners
wait and retry.

Within the operator's own account,
[`modules/nixos/dev-cpu-shares.nix`](../modules/nixos/dev-cpu-shares.nix)
caps the agent terminals (`manifold-terminal-host`: eight cores, half weight)
and myParcelle's follow-main rebuilds (`myparcelle-dev-follow`: two cores,
weight 20) as drop-ins, so the development surface and the terminals keep
their share of the twelve cores when CI and rebuilds run at once.

[`modules/nixos/myparcelle-ci-clever.nix`](../modules/nixos/myparcelle-ci-clever.nix)
runs the controller of myParcelle's on-demand CI machines on Clever Cloud
(labels `self-hosted`, `linux`, `x64`, `clever`; a trial until 2026-11-30).
The machines run on Clever; only the controller runs here, as the
`myparcelle-ci-clever` system account, from a root-owned copy of
myParcelle's `deploy/ci-runners/` at `/var/lib/myparcelle-ci-clever-source`,
placed by hand from a reviewed commit (the module's header has the refresh
commands). A watchdog timer, apart from the controller, sends CI back to
dev-01 and alerts `#alertes` when `clever` jobs wait three minutes with
nothing serving them. Its credentials are systemd
credentials from root-only files: the runners' GitHub token and the
controller's own Clever OAuth token at
`/var/lib/myparcelle-ci-runners/clever-oauth.json`, which myParcelle's
`deploy/ci-runners/mint-clever-token.ts` writes after the operator approves
the consumer in his browser. Until that file and the source copy exist, the
units do not start.
Its cost ledger and daily cost lines are in `/var/lib/myparcelle-ci-clever`.

[`modules/nixos/myparcelle-ci-clever-guard.nix`](../modules/nixos/myparcelle-ci-clever-guard.nix)
is its cost guard, apart from it and sharing no state with it: every two
minutes it reads Clever itself and stops CI machines running over 70 min, any
beyond the controller's limit, and all of them when it cannot read Clever for
15 min. Today's CI spend reaching €15, or the month's €100, pulls a kill switch:
the controller stopped and refused, every machine stopped, CI back on dev-01,
and a latch in `/var/lib/myparcelle-ci-clever-guard` that only a human removes.
The caps are in `/etc/myparcelle-ci-clever-guard.env`, from the module.

The games edge sends `games.tyrode.dev` to `127.0.0.1:8093`. The
[game checkout](https://github.com/atyrode/scrabble/tree/dev) owns its path
routing and Docker Compose runtime, including hot reload during development.
Ordinary application edits do not require host configuration changes or
activation. Caddy owns HTTPS and certificates; stopping the game leaves an
unavailable upstream rather than serving another application.

The kroissant edge sends `kroissant.tyrode.dev` to `127.0.0.1:8094`. The
site's checkout owns its Docker Compose development stack (`local/`, with live
reload) and publishes it on that loopback port; production is hosted
elsewhere and never behind this edge. Ordinary site edits do not require host
configuration changes or activation; stopping the stack leaves an unavailable
upstream.

The house-studio edge sends `studio.tyrode.dev` to `127.0.0.1:8095`. The
studio's checkout owns its Docker Compose runtime and keeps its data (projects,
owner key, agent keys) in a directory outside the checkout; the studio
authenticates its own users and agents, so the edge adds only TLS. Ordinary
studio edits do not require host configuration changes or activation; stopping
the stack leaves an unavailable upstream.

The parxel edge sends `parxel.tyrode.dev` to `127.0.0.1:4175`, where the
parxel design-preview checkout publishes its Vite development server; hot
reload's WebSocket upgrade passes through the same vhost. The preview is
static and holds no data, so the edge adds only TLS and compression, and it is
independent of the parcel edge above. Ordinary preview edits do not require
host configuration changes or activation; stopping the server leaves an
unavailable upstream.

`wsl` is a deliberate local-workstation exception: this flake exports its
complete `nixosConfigurations` entry and owns that WSL guest, while native
Windows packages and state retain their separate WinGet/application boundary.
The full Home Manager, nix-darwin, NixOS-WSL, and Windows ownership model is
documented in [Home Manager and system boundary](system-boundary.md).

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
