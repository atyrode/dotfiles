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
POSTs the canonical fleet name to `/api/actions/core.machines.enroll`, and installs the minted
token at `~/.config/manifold/machine.token` (0600, in a 0700 directory).
The owner key never enters argv, logs, or disk outside the secure temp dir;
the running agent never touches the vault.

Re-running with an existing token neither contacts the vault/master nor
restarts an active agent. It starts an inactive managed service and fails if
that start fails. A lost token is recovered explicitly with `--rotate-token`.
Before touching the vault, hub or token, rotation proves that the managed agent
is inactive or transport-only. A live legacy owner, an unreadable manager or a
disagreement between deployed and loaded definitions refuses the operation.
Never rotate merely to repair a protocol mismatch.

The declared service waits for its token before starting. Linux uses
`ConditionPathExists`; launchd uses `KeepAlive.PathState` and logs to
`~/.local/state/manifold/agent.log`. Enrollment loads/starts the service in
the current user's session. Headless Linux machines need user lingering so
the agent survives logout; managed NixOS owns that setting. The macOS agent
lives in the logged-in user's GUI session, not a system daemon.

`phase: "connected"` in runtime status proves a current hub connection, followed
by the named machine appearing on the canvas. It does **not** prove maintenance
preserved workloads. Preservation additionally requires the expected terminal
IDs, the same running workloads, and working input/output after the transition.
An empty replacement inventory is a maintenance failure, not recovery.

## Upgrades

The released combined agent owns its PTY masters and deliberately terminates
them on shutdown. Starting a second combined agent with the same token can also
supersede the incumbent and reconcile away its inventory. Never use a production
machine token for a replacement smoke test.

A task's Git diff is not its activation scope: compare the running generation
with the entire built candidate, including embedded Home Manager units. A
same-version executable-path or environment change can restart a service.
Running an apply over ordinary SSH protects the deployer's connection, **not
anyone else's terminals**. It is not permission to replace a live PTY owner.

The continuity architecture in manifold #278 separates the terminal host from
the networking agent. The terminal host has its own service lifetime and a
stable managed-profile command, so a transport pin update does not replace the
running owner. Linux also keeps the split terminal host across definition
changes and refuses direct stops; macOS keeps an unchanged loaded owner plist.
The legacy Linux combined agent is retained across activation too, but does
not refuse a deliberate manager stop after its workloads have finished.

The first migration cannot transfer existing PTY masters between processes.
After promoting a compatible hub, close admission with `core.machines.drain`,
then finish or deliberately close **every** legacy terminal. A legacy agent
cannot acknowledge the new drain handshake; the hub still keeps admission
closed. Once its inventory is empty, stop the legacy owner explicitly:

```sh
# Linux, as the enrolled user:
systemctl --user stop manifold-agent.service
# macOS, in the enrolled user's GUI session:
launchctl bootout "gui/$(id -u)/org.nix-community.home.manifold-agent"
```

Then apply the split topology, verify the owner and transport, and cancel the
drain. These raw manager commands are deliberate legacy maintenance, not an
automatic bypass in `atyrode runtime`. Never overlap owners or test replacement
with a production token. This initial maintenance boundary cannot be made
lossless by CLI automation; subsequent transport updates retain the PTY owner.

Release, promotion, pin publication and activation are distinct operations:

1. Publish and verify the release. Publication is not production deployment.
2. Promote the target hub deliberately before installing a newer-protocol
   agent; compatibility accepts older agents, not newer ones.
3. Refresh the transport pin only after compatibility is proven. Restarting the
   retained terminal host to use newly installed code is separate maintenance,
   never an incidental transport update.
4. Inspect and enforce the exact running-to-candidate disruption report before
   activation. Unknown effects or a protected-owner replacement must refuse;
   neither `--yes` nor a successful package build proves preservation.
5. Verify expected terminal identity, workload continuity and usable I/O after
   an allowed transport replacement.

On dev-01, `atyrode apply` converges that local machine; `atyrode fleet apply
dev-01` requests convergence from another operator device. Both paths must obey
the same activation safety contract.

The pin refresh enforces hub compatibility. `ci/update-pins.sh` carries a
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

An unmanaged combined agent is still a live terminal owner. Converting it to
a managed service is not safe while its workloads remain, whether the command
is issued over SSH or from a Manifold terminal.

Close new admission and let existing workloads finish before replacing that
owner. Prevent its old supervisor from respawning it; do not start a same-token
replacement alongside it. If the deployed version cannot establish a race-free
drain, stop and arrange explicit legacy maintenance rather than infer safety
from a sampled zero count.

Enrollment need not change: retain the existing machine credential and never
rotate it as a deployment workaround. A subsequent `phase: "connected"` proves
connectivity only; it cannot turn unexpected terminal loss into success.

## The preview tier on dev-01

`dev-01` is a spoke of the master like every machine here, and it also hosts
everything one iterates on, under one wildcard.
[`modules/nixos/manifold-dev-hub.nix`](../modules/nixos/manifold-dev-hub.nix)
fronts two names with Caddy, sharing the VPS's ports 80 and 443 with the
[parcel development edge](hosts.md#current-capabilities):

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
