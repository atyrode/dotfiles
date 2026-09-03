# Manifold fleet node

The `manifold-node` capability makes a dotfiles machine a spoke of the
self-hosted manifold hub ([atyrode/manifold](https://github.com/atyrode/manifold),
dotfiles issue #418): a `manifold-agent` user service dials out to the master
over WebSocket and exposes the machine's terminals on the shared canvas. There
are no inbound ports, no mesh, and no election — one hub, many spokes.

## Ownership split

- **Git owns master discovery.** `fleet/manifold.json` declares
  `masterUrl` and `masterHost`; repointing the fleet is a reviewed commit.
  Vault write access can never redirect fleet terminals (the Bitwarden-based
  discovery alternative was rejected in #418 for exactly that reason).
- **Nix owns the agent and its unit.** The `manifold-node` capability installs
  the pinned `manifold-agent` (a release-asset pin, like omp/code/codex —
  the upstream flake's bun-deps derivation is not reproducible across
  machines, atyrode/manifold#51) and a `systemd --user` unit that executes
  the immutable store binary with `Restart=always`, a bounded delay, and the
  committed master URL. The capability currently delivers on `x86_64-linux`
  only — widen `supportedSystems` in `fleet/manifold.json` as upstream
  publishes assets for more platforms.
- **The runtime layer owns machine state.** Enrollment and the machine token
  live outside the Nix store, exactly like `local-qwen`.

## Enrollment

```sh
atyrode runtime provision manifold-agent
atyrode runtime status manifold-agent --json
```

Provisioning is interactive and one-time: it reads the manifold owner key from
the Bitwarden Secure Note named by `vaultItemName` (under the same
unlock→fetch→lock discipline as `atyrode auth broker setup`), POSTs the machine's
hostname to `/api/machines`, and installs the minted token at
`~/.config/manifold/machine.token` (0600). The owner key never enters argv,
logs, or disk outside the secure temp dir; the running agent never touches the
vault. Re-running is idempotent. A lost token is recovered explicitly with
`--rotate-token`, which revokes the old token immediately — a live agent still
using it is fenced.

The unit is inert (`ConditionPathExists` on the token file) until enrollment,
so applying the capability before provisioning is safe everywhere. Headless
machines need user lingering (`loginctl enable-linger`) so the agent survives
logout; on the managed NixOS server that is system-owned.

## Upgrades

Starting or restarting an agent is destructive twice over: a restart kills
every PTY the old process owns, and a *new* agent presenting the same machine
token supersedes the live one on hello — the hub closes the older socket and
reconciles away every session the newcomer does not advertise. Upgrades are
therefore operator-timed:

1. Upgrade the hub first (protocol compat accepts older agents; the reverse is
   rejected loudly). The DB lives in the `manifold-data` named volume, in WAL
   mode — never `cp` it live. Snapshot before any upgrade that applies a
   schema migration, and stamp the build so `/healthz` proves what deployed:

   ```sh
   cd ~/manifold && git pull --ff-only
   docker exec manifold-manifold-1 bun -e \
     'import {Database} from "bun:sqlite";
      new Database("/data/manifold.db").exec("VACUUM INTO '/data/pre-upgrade.db'")'
   docker cp manifold-manifold-1:/data/pre-upgrade.db /srv/backups/
   MANIFOLD_BUILD=$(git rev-parse --short HEAD) docker compose build
   MANIFOLD_BUILD=$(git rev-parse --short HEAD) docker compose up -d
   curl -s https://manifold.tyrode.dev/healthz   # build must equal the new rev
   ```

2. Bump the `manifold` pin (`./ci/update-pins.sh manifold`) and merge.
   Applying that generation restarts the agent on each machine as its unit
   changes — apply on a machine hosting live manifold sessions from a plain
   SSH session, never from inside one of its own terminals.

On dev-01 the capability arrives through that machine's own entry in
[`fleet/hosts.nix`](../fleet/hosts.nix): it is a machine of this repository,
so delivery is `atyrode fleet apply dev-01` from an operator device,
not `atyrode apply`, which converges only the machine it runs on.

The pin refresh enforces step 1. `ci/update-pins.sh` carries a
`guard_manifold` precondition: it reads the hub's `/healthz` protocol version
and the candidate tag's `PROTOCOL_VERSION`, and holds the bump whenever the
candidate is newer, or whenever it cannot prove otherwise (unreachable hub,
unreadable constant). A held bump prints to stderr and to the Actions job
summary, opens no pull request, and leaves the pin untouched. Clearing it means
deploying the hub, not overriding the guard.

### Protocol mismatch is silent

An agent newer than the hub does not crash. The hub closes every dial with
`4409 protocol version mismatch`; the agent logs the rejection, schedules a
reconnect, and stays `active (running)` indefinitely, so `Restart=always` has
nothing to act on and the machine looks healthy while being absent from the
canvas. An unattended pin bump has shipped such an agent to a spoke once
(dotfiles #452), because a green gate said nothing about the deployed hub;
that is what `guard_manifold` above exists to prevent.

A spoke that has silently left the hub is therefore diagnosed from the agent's
journal rather than from its unit state:

```sh
journalctl --user -u manifold-agent -n 20   # welcome = joined; 4409 = locked out
curl -s https://manifold.tyrode.dev/healthz # hub protocolVersion
```

Rolling a bad pin back needs a local checkout
(`atyrode apply --repo ~/nix-dotfiles`), because plain `atyrode apply` builds
the published revision and so cannot carry an unmerged fix.

## Replacing an unmanaged agent (#419)

A machine may already carry a detached agent started outside Nix. Swapping it
for the declared user service is safe under two constraints, both structural
rather than particular to one host:

- Run the swap from plain SSH, never from a manifold terminal. Starting the
  declared service kills the unmanaged process's PTYs, including the session
  that issued the command.
- Delete the unmanaged definitions only after the service reports `welcome`. A
  respawned process presenting the same token can otherwise fence the
  service-managed socket.

Enrollment survives the swap untouched: the existing 0600 machine token is
adopted as-is, never re-minted. `atyrode runtime status manifold-agent --json`
is the proof it worked, reporting `enrolled: true` with `unit.present: true`
and an active unit.

## Master migration

The master is a stateful pet: `manifold.db` in the `manifold-data` volume
holds pads, scenes,
principals, and hashed tokens. No backup engine covers it yet (ADR 0002 gates;
SQLite online-backup class), so pads are not durable state.
Migration is snapshot → restore on the new host → edit
`fleet/manifold.json` → merge → `atyrode apply` fleet-wide. Never run two
masters: agents hold one token for one hub, and two SQLite stores cannot be
reconciled.
