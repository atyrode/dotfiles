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
  installs the independently pinned release asset. Linux uses
  `systemd --user`; Apple Silicon macOS uses a Home Manager launchd agent.
  Both execute the immutable store binary against the committed master URL.
  `fleet/manifold.json` declares the supported systems; which machines are
  spokes is the `manifold-node` capability in `fleet/hosts.nix`, the one
  place a machine is named. Portable development profiles do not enroll
  client machines into the fleet.
- **Clan owns the credentials.** The hub's owner key and each spoke's machine
  token are clan vars ([secrets.md](secrets.md#declaring-a-secret)),
  encrypted in the repository and placed by activation, exactly like Babel's
  custody. The vault is not involved in Manifold at all.
- **The overlay is not manifold's.** The fleet's WireGuard overlay (ADR 0008,
  #582) is substrate: it lets `atyrode fleet apply` and the backup routine
  reach machines that expose no port. Manifold neither uses nor knows it: the
  agent dials the hub's public origin from wherever it is, the hub brokers
  every terminal itself and never opens a machine-to-machine path, and it
  stays off the overlay so that a client machine on a portable profile can be
  a spoke too. Nothing in the overlay's configuration names manifold and
  nothing here names the overlay; the two answer different questions (what
  can I see and drive; what can reach what) and stay in their own repository.

## Enrollment

Enrolling happens on an operator device, because it is an HTTP call that
needs the hub's owner key, and no machine of the fleet holds that key:

```sh
clan vars generate <host> --generator manifold-custody   # once, fleet-wide
atyrode runtime enroll manifold-agent <host> --repo ~/nix-dotfiles
```

The owner key is the shared var `manifold-custody/owner-key`
([`modules/shared/manifold-agent.nix`](../modules/shared/manifold-agent.nix)):
encrypted to the admins group and never deployed (`deploy = false`), so it
exists only as an input the operator entered once. Enrolling reads it with
`clan vars get`, POSTs the canonical fleet name to
`/api/actions/core.machines.enroll`, reads the `ActionOutcome` envelope (a
refusal is HTTP 200 with `ok: false` and the rule that refused), and stores
the minted token as the machine's own var `manifold-agent/machine-token`
with `clan vars set` over stdin, then names the commit clan made for review.
The owner key travels through a 0600 curl config in a secure temp dir and
never enters argv, logs, or a machine. When custody is missing, the CLI names
the `clan vars generate` step above rather than guessing. A device that
still holds its own token as a plain file, from before the token was a clan
var, has that file adopted into clan rather than re-minted, so the cutover
rotates nothing.

On the machine, the token is what activation placed: sops-nix writes it to
`/run/secrets/vars/manifold-agent/machine-token`, mode 0600 and owned by the
account whose agent reads it, and Home Manager forces the link
`~/.config/manifold/machine.token` onto it, so the native units and
`atyrode runtime` read the path they always have. Until the var exists the
link dangles, and a dangling link is the inert unenrolled state.

```sh
atyrode runtime provision manifold-agent
atyrode runtime status manifold-agent --json
```

Provisioning on the machine never mints: it starts the agent for a placed
token and otherwise fails naming the operator-device command. `doctor
provisioning` reports an unenrolled spoke as degraded with that same
remediation -- told, not offered, since the ceremony cannot run here. With a
placed token, re-running neither contacts the master nor restarts an active
agent: it starts an inactive managed service and fails if that start fails.

A lost token is recovered explicitly with `--rotate-token`, again on an
operator device. Rotation revokes the token the running agent holds, so it
says what that ends before asking the hub; once the new value is stored, the
machine needs `atyrode apply` to place it and `atyrode runtime restart
manifold-agent` to load it. Never rotate merely to repair a protocol mismatch.

The declared service waits for its token before starting. Linux uses
`ConditionPathExists`; launchd uses `KeepAlive.PathState` and logs to
`~/.local/state/manifold/agent.log`. Provisioning loads/starts the service in
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
dev-01 --repo PATH` requests convergence from another operator device. Both paths must obey
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

The bounded cutover will retain the existing Compose project and
`manifold-dev_manifold-data` volume under Manifold's preview receiver.
Home Manager declares the receiver's public `~/manifold-previews/env`
settings: hub-only operation with `MANIFOLD_DEV_SPAWN_AGENT=0` and
`MANIFOLD_DEV_SERVICE_OWNER_MACHINE_ID` set to the enrolled preview
machine's opaque ID. The hub never
chooses a service owner by display name or falls back to another machine.
Back up the retained volume before a deployment that crosses a schema version.

The separate preview executor is declared in
`modules/nixos/manifold-dev-hub.nix` through Manifold's `nixosModules.native`
profile at merged revision `3de83c4abb7b44830d19c02cbb5c0cec75ef95fa`
(Manifold #463), recorded in `flake.lock` and imported only for dev-01.
It runs the same execution-only profile documented for ordinary multi-node
self-hosting: `manifold-owner` retains jobs and PTYs; `manifold-transport`
can be replaced independently. The existing Compose hub, Caddy edge and
ordinary Home Manager `manifold-agent` are not replaced or repointed.

The declaration contains only the enrolled preview ID, public admission
verifier, reviewed artifact origins and explicit runtime-resource bindings.
The `tokenCredentialFile` reference names the incumbent
`~/.config/manifold/dev/machine.token` under the operator's existing custody.
On separately authorized activation, systemd's `LoadCredential` delivers it
privately to the transport while the source remains in its existing custody.
The native profile first checks source metadata: a regular non-symlink file
with mode 0400 or 0600, neither it nor any ancestor owned by `manifold` or
writable by group/others (including ACL masks). It refuses unsafe custody
rather than repairing it. This source declaration does not establish that the
live file or its ancestors satisfy those prerequisites; none have been inspected.
There is no agent-managed token copy, rotation, ownership repair or additional
source read access. The profile
protects the traversable `/home` ancestor so the
operator's mode-0700 home need not be weakened, and excludes generated
systemd credential directories from workloads. Token bytes never enter Nix
or a derivation. The ordinary fleet token and provider-authentication stores
are not inputs to this profile.

The separate `development` tool group supplies the ordinary Code launch's
shell, coding utilities, Git and Python. `runtimeToolClosures.development`
expands the declared `developmentRuntime` package closure at build time into
read-only bindings at exact immutable store paths, with explicit `/usr/bin`, `/bin/sh`
and `/bin/bash` entrypoints. This is not a host PATH, whole-store mount or a
global Python environment; project-specific dependencies remain local to the
workspace. Account sign-in and shared service workers keep their narrower
library/managed-runtime bindings.

The `system` group also binds the existing systemd-resolved stub to
`/etc/resolv.conf` and the machine's configured public CA bundle to
`/etc/ssl/certs/ca-certificates.crt`. Code's reviewed operation environment
points TLS clients at that bundle; Git receives its explicit CA setting.
No host `/etc` directory or ambient environment is mounted. The native owner
starts after the resolver, but resolver restarts do not stop the owner.

The pin and declarations are source integration only: no legacy retirement,
credential handoff, native activation or admission reopening has been performed
by this change. Source publication (including updating the pinned Manifold
input) is not authorization to activate this transition, nor does it replace
the required current-revision native-profile, flake and CI gates.
The supported operator handoff is
Manifold's `infra/previews/retire-spoke.sh`, using the merged
`manifold-agent --maintenance` API. Run it only with separate live-maintenance
authorization, as the account owning the old user units. Its explicit public
arguments are `--container`, `--machine-id`, `--terminal-host-id`,
`--terminal-host-unit`, `--transport-unit`, `--socket` and
`--runtime-dir "$XDG_RUNTIME_DIR"` (the owning user's mode-0700 runtime directory
for the public maintenance bundle and serialization lock). The reviewed machine
ID is `05df7eaa-efd8-4d9c-bb0c-334706555c77`; the units are
`manifold-dev-terminal-host.service` and `manifold-dev-agent.service`.
Select the incumbent Compose container, terminal-host identity and absolute
socket path from the reviewed deployment's public configuration, not a guessed
PID or a private state file. The command reads the hub's owner key only inside
that owning container: never extract the key, enrollment token or provider
state into a shell, Nix input or handoff transcript.

Retirement uses `core.machines.drain` for that exact machine and requires
positive-empty evidence; busy or unknown state fails closed. It never
finishes, cancels or kills retained work: the operator must finish that work
through its native controls. The command requires the owner's atomic
`shutdown_request` acknowledgment before retiring
its old supervisors; on shutdown refusal it restores the transport but leaves
admission closed. Empty-looking process listings are not shutdown proof. The
helper does not activate Nix or reopen admission. Preserve the existing Compose
project, data volume, identities, credential-file reference and every workload
directory; neither this handoff nor a retained hub replacement recursively
chowns or migrates them. Never overlap two transports using the enrolled
token, rotate credentials merely to change supervision, or substitute another
machine's credentials. The shared receiver now runs the server-only image;
there is no legacy spoke rebuild/restart hook. Numbered disposable previews
keep their separate, explicit disposable lifecycle.

An unrelated system activation cannot bypass the source-managed startup
prerequisite `manifold-preview-legacy-guard.service`. On every native owner or
transport start it first resolves the existing account's public UID and
explicitly starts/waits for its systemd user manager. It then queries both
declared old units through that manager. Each must be `inactive`/`dead`, with
no pending job or stale manager metadata, and a disabled, persistently masked
or demonstrably absent unit definition. The manager's declared trigger/upholder,
reverse Wants/Requires/BindsTo, success/failure (both directions), and
PartOf/ConsistsOf relationships may name only the two independently checked old
units. Any external edge blocks startup even when its source is inactive:
in particular, a timer targeting a wrapper that wants an old unit is not
retirement. This is a bounded dependency snapshot, not permission for later
privileged reconfiguration. Enabled, runtime-only masked, failed, activating
and unknown states all block startup; an unavailable user bus or
failed/incomplete metadata query also blocks it.
The guard never stops, disables, masks or kills either old supervisor and
never reads or repairs its state. It runs before private owner configuration
publication and before PID 1 loads the transport's credential, not as an
activation-time migration.

Only the acknowledged retirement and stopped/disabled supervisors permit
separately authorized native-profile activation. The prerequisite has no
cached retirement marker or persistent success state, and no lifetime
dependency from the retained owner to the user manager. A later user-manager
or resolver restart therefore does not stop the native owner. Failed
preconditions require completing the authorized handoff, not weakening the
guard or making activation retire the old owner automatically.

Routine hub or transport updates must retain the owner PID and running
workloads. Owner configuration changes require the same explicit maintenance;
the profile refuses drift rather than rewriting a live owner's configuration.
`fleet/service-protection.json` and the native units' session-owner markers
keep that distinction visible to `atyrode apply`. Verify native readiness and
retained workloads before explicitly reopening admission.

## Master migration

The master is a stateful pet: `manifold.db` holds containers, scenes,
principals, and hashed tokens, replicated continuously to an S3-compatible
store by the deployment itself (atyrode/manifold `docs/SELF-HOST.md`
§Replicate the database). Migration is snapshot → restore on the new host →
edit `fleet/manifold.json` → merge → apply fleet-wide. Never run two masters:
agents hold one token for one hub, and two SQLite stores cannot be
reconciled.
