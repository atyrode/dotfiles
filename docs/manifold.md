# Manifold fleet node

The `manifold-node` capability makes a dotfiles machine a spoke of the
self-hosted manifold hub ([atyrode/manifold](https://github.com/atyrode/manifold),
dotfiles issue #418): a `manifold-agent` user service dials out to the master
over WebSocket and exposes the machine's terminals on the shared canvas. There
are no inbound ports, no mesh, and no election — one hub, many spokes.

## Ownership split

- **Git owns master discovery.** `inventory/manifold.json` declares
  `masterUrl` and `masterHost`; repointing the fleet is a reviewed commit.
  Vault write access can never redirect fleet terminals (the Bitwarden-based
  discovery alternative was rejected in #418 for exactly that reason).
- **Nix owns the agent and its unit.** The `manifold-node` capability installs
  the pinned `manifold-agent` (a release-asset pin, like omp/code/codex —
  the upstream flake's bun-deps derivation is not reproducible across
  machines, atyrode/manifold#51) and a `systemd --user` unit that executes
  the immutable store binary with `Restart=always`, a bounded delay, and the
  committed master URL. The capability currently delivers on `x86_64-linux`
  only — widen `supportedSystems` in `inventory/manifold.json` as upstream
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
unlock→fetch→lock discipline as `atyrode backup setup`), POSTs the machine's
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

2. Bump the `manifold` pin (`./scripts/update-pins.sh manifold`) and merge.
   Applying that generation restarts the agent on each machine as its unit
   changes — apply on a machine hosting live manifold sessions from a plain
   SSH session, never from inside one of its own terminals.

On tyrode-dev-01 the capability arrives through the `alex-x86_64-linux`
registry entry, which tyrode-dev/infra consumes via its dotfiles flake pin:
delivery there is a pin bump in that repository plus `atyrode infra apply`
(interactive: Bitwarden unlock for the Clan operator identity), not
`atyrode apply`.

## tyrode-dev-01 cutover (#419)

The VPS currently runs a detached OMP-managed stopgap agent pinned to v0.3.1;
it is not host-supervised and holds the operator's own working sessions. The
swap to the declared service kills those PTYs, so it must be run from plain
SSH, never from a manifold terminal:

1. From SSH: `atyrode runtime status manifold-agent --json` — confirm
   `enrolled: true` (the existing 0600 token is adopted as-is; no re-mint).
2. Deploy the generation that delivers the unit (`atyrode infra apply`), then
   `systemctl --user start manifold-agent` and verify `welcome` in
   `journalctl --user -u manifold-agent` (status reports
   `lastLogEvent: "welcome"`, phase `connected`).
3. Only then stop and delete the OMP stopgap definitions (`omp` process
   `manifold-agent-devbox` and any recovery entries) so a respawned stopgap
   can never fence the service-managed socket by presenting the same token.
4. Confirm the hub lists the machine online and re-adopts surviving PTYs.

## Master migration

The master is a stateful pet: `manifold.db` in the `manifold-data` volume
holds pads, scenes,
principals, and hashed tokens. Until tyrode-dev/infra's backup engine covers
it (ADR 0002 gates; SQLite online-backup class), pads are not durable state.
Migration is snapshot → restore on the new host → edit
`inventory/manifold.json` → merge → `atyrode apply` fleet-wide. Never run two
masters: agents hold one token for one hub, and two SQLite stores cannot be
reconciled.
