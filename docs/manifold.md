# Manifold fleet node

The `manifold-node` capability makes a dotfiles machine a spoke of the
self-hosted manifold hub ([atyrode/manifold](https://github.com/atyrode/manifold),
dotfiles issue #418): a `manifold-agent` user service dials out to the master
over WebSocket and exposes the machine's terminals on the shared canvas. There
are no inbound ports, no mesh, and no election — one hub, many spokes.

## Ownership split

- **Git owns master discovery.** `fleet/manifold.json` declares `masterUrl`;
  repointing the fleet is a reviewed commit. The master is not a machine of
  this fleet: it is the operator's Clever Cloud deployment of atyrode/manifold
  (its ADR 0022, `manifold.tyrode.dev` since 2026-09-05), released by
  `bun run release` there and never by an apply here.
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
unlock→fetch→lock discipline as `atyrode provision git`), POSTs the machine's
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
   rejected loudly). The hub is released upstream: `bun run release` in
   atyrode/manifold publishes the tag, its `Deploy hub` workflow deploys the
   operator's instance, and `curl -s https://manifold.tyrode.dev/healthz`
   reports the tag as `build`.

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

## The development hub on dev-01

`dev-01` is a spoke of the master like every machine here, and it also hosts
the hub one iterates on: a compose stack the operator runs from a checkout on
port 7912, which [`modules/nixos/manifold-dev-hub.nix`](../modules/nixos/manifold-dev-hub.nix)
fronts as `dev.manifold.tyrode.dev` with Caddy and a Let's Encrypt
certificate. That module is why the VPS opens 80 and 443 beside SSH. The
stack itself is not declared: it is started by hand from the checkout, and a
vhost whose upstream is down answers 502, which is what "not running" should
look like.

## Master migration

The master is a stateful pet: `manifold.db` holds containers, scenes,
principals, and hashed tokens, replicated continuously to an S3-compatible
store by the deployment itself (atyrode/manifold `docs/SELF-HOST.md`
§Replicate the database). Migration is snapshot → restore on the new host →
edit `fleet/manifold.json` → merge → apply fleet-wide. Never run two masters:
agents hold one token for one hub, and two SQLite stores cannot be
reconciled.
