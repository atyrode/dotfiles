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
- **Nix owns the agent and its native service.** The `manifold-node` capability
  installs the pinned release asset (the upstream flake's bun-deps derivation
  is not reproducible across machines, atyrode/manifold#51). Linux uses
  `systemd --user`; Apple Silicon macOS uses a Home Manager launchd agent.
  Both execute the immutable store binary against the committed master URL.
  `fleet/manifold.json` declares the supported systems and every owned spoke:
  `macbook`, `wsl`, and `dev-01`. Portable development profiles do not enroll
  client machines into the fleet.
- **The runtime layer owns machine state.** Enrollment and the machine token
  live outside the Nix store, exactly like `local-qwen`.

## Enrollment

```sh
atyrode runtime provision manifold-agent
atyrode runtime status manifold-agent --json
```

After activation, `atyrode apply` offers enrollment when the installed
capability has no token. It remains an authorized, interactive operation:
it reads the owner key from the Bitwarden Secure Note named by `vaultItemName`
(under the same unlock→fetch→lock discipline as `atyrode provision git`),
POSTs the canonical fleet name to `/api/machines`, and installs the minted
token at `~/.config/manifold/machine.token` (0600, in a 0700 directory).
The owner key never enters argv, logs, or disk outside the secure temp dir;
the running agent never touches the vault.

Re-running with an existing token neither contacts the vault/master nor
restarts an active agent. It starts an inactive managed service and fails if
that start fails. A lost token is recovered explicitly with `--rotate-token`:
this revokes the old token, fences its holder, and restarts a running managed
agent to load the replacement. Never rotate merely to repair a protocol
mismatch.

The declared service waits for its token before starting. Linux uses
`ConditionPathExists`; launchd uses `KeepAlive.PathState` and logs to
`~/.local/state/manifold/agent.log`. Enrollment loads/starts the service in
the current user's session. Headless Linux machines need user lingering so
the agent survives logout; managed NixOS owns that setting. The macOS agent
lives in the logged-in user's GUI session, not a system daemon.

Acceptance is `phase: "connected"` in runtime status, followed by the named
machine appearing on the canvas. `enrolled` or `running` alone is not proof
of a hub connection, and provisioning doctor does not mark it healthy.

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

### Protocol mismatch does not stop the process

An agent newer than the hub does not crash. The hub closes every dial with
`4409 protocol version mismatch`; the agent logs the rejection, schedules a
reconnect, and stays active indefinitely, so a service manager cannot diagnose
the absent canvas node by process state alone. An unattended pin bump shipped
such an agent once (dotfiles #452); `guard_manifold` prevents that release
ordering error.

Runtime status inspects structured connection events as well as process
state. A restart or disconnect invalidates an earlier welcome, and a
rejection makes provisioning doctor degraded. Inspect the native log for
the cause:

```sh
journalctl --user -u manifold-agent -n 20   # welcome = joined; 4409 = locked out
tail -n 20 ~/.local/state/manifold/agent.log # macOS equivalent
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
is the proof it worked, reporting `phase: "connected"`. An enrolled token
and an active process without a current welcome are not enough.

## The preview tier on dev-01

`dev-01` is a spoke of the master like every machine here, and it also hosts
everything one iterates on, under one wildcard.
[`modules/nixos/manifold-dev-hub.nix`](../modules/nixos/manifold-dev-hub.nix)
fronts two names with Caddy, and is why the VPS opens 80 and 443 beside SSH:

- `preview.manifold.tyrode.dev` — the integrated instance: every green `main`
  of atyrode/manifold, on the compose stack the operator runs from
  `~/manifold-dev` on port 7912.
- `*.manifold.tyrode.dev` — one hostname per pull request (`283.…`) or live
  worktree (`<name>.…`), proxied to an operator-owned router on 127.0.0.1:7900
  that manifold's `infra/previews/preview.sh` generates as previews come and
  go. Certificates are issued on demand, per hostname, only for names the
  router vouches for.

Both are driven from GitHub through one deploy key
([`modules/home/ssh/deploy-keys`](../modules/home/ssh/deploy-keys)): a
forced-command SSH key whose only power is to run
`~/manifold-dev/infra/previews/receiver.sh`, which deploys `main` or brings a
preview up or down. The private half is atyrode/manifold's
`DEV_DEPLOY_SSH_KEY` repository secret. The stacks themselves are not
declared here: they are the operator's checkouts, and a vhost whose upstream
is down answers 502, which is what "not running" should look like. DNS:
`preview` and `*` A records to this machine; the apex stays the master's.

Concretely, as of 2026-09-05: the checkout is `~/manifold-dev` (a git worktree
of `~/manifold`), its `.env` sets `COMPOSE_PROJECT_NAME=manifold-dev` and
`COMPOSE_FILE=compose.yaml:/home/alex/manifold-dev-deploy/compose.dev.yaml`,
and that overlay publishes `127.0.0.1:7912:7777`, names the in-container
machine `dev-hub`, and parks the bundled caddy behind a profile. A deploy is
`git -C ~/manifold-dev checkout <rev>` then, from that directory,
`MANIFOLD_BUILD=$(git rev-parse --short HEAD) docker compose up -d --build manifold`;
`/healthz` reports the revision. Back the volume
(`manifold-dev_manifold-data`) up before a deploy that crosses a schema
version; `~/manifold-dev-deploy/backups/` holds the tarballs.

The dev hub has its own spoke on the same machine, and it is by-hand for the
same reason the stack is: it must track a checkout revision, not a release
pin. `~/.config/systemd/user/manifold-dev-agent.service` (hand-written, not
Home Manager's) runs `~/.local/share/manifold-dev-agent/manifold-agent`, built
with `bun build --compile packages/agent/src/main.ts` from the revision the dev
hub runs, enrolled as `dev-01` on `https://dev.manifold.tyrode.dev` with its
token at `~/.config/manifold/dev/machine.token`. It is a second
`manifold-agent` process beside the Home Manager unit and shares nothing with
it: different hub, different token file, different `MANIFOLD_BUILD`. After a
dev-hub deploy that changes the agent wire, rebuild the binary, update the
unit's `MANIFOLD_BUILD`, and `systemctl --user restart manifold-dev-agent`.
Never point this unit at the master: the master's spoke is the declared one.

## Master migration

The master is a stateful pet: `manifold.db` holds containers, scenes,
principals, and hashed tokens, replicated continuously to an S3-compatible
store by the deployment itself (atyrode/manifold `docs/SELF-HOST.md`
§Replicate the database). Migration is snapshot → restore on the new host →
edit `fleet/manifold.json` → merge → apply fleet-wide. Never run two masters:
agents hold one token for one hub, and two SQLite stores cannot be
reconciled.
