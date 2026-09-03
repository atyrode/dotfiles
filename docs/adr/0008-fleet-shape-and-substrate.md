# ADR 0008: Fleet shape, substrate, and the road there

- Status: Accepted
- Date: 2026-09-01, accepted 2026-09-02, amended 2026-09-02 (clan, layout)
- Supersedes: [0005](0005-no-declarative-secret-manager.md) — its stated
  trigger ("a concrete secret must be delivered declaratively") has fired.

This record lives in a public repository, so it names roles and machines,
never providers, prices, addresses or keys. Every choice below is either
**decided** or explicitly **open**, and nothing marked open is built
until the operator closes it. The fleet stays usable at every step of the
roadmap; no step may leave a machine that cannot converge.

## Context

The repository grew into a platform run by one person: a fleet of machines, a
9,800-line Bash CLI with its own convergence model, a second convergence model
in `install.sh`, three agent tools that each carry a little cross-machine glue
(`code`, `babel`, `manifold`), a production server managed from a separate
9,500-line repository, and secrets fetched by hand from Bitwarden on every
machine. Eight problems follow from that shape, in the order they surfaced.
Bootstrap is an interactive chain of commands and yes/no questions, so no
machine can be brought up unattended. Machines drift, because nothing pushes a
converge and nothing reports how far behind a machine is. A release of a fleet
tool costs two repositories, two CI waits and four manual applies. Secrets are
scattered across machines with a Bitwarden session as the only glue, so every
machine needs an interactive login before it can read a value. Agent context is
not generated, so an agent starts every project on every machine knowing
nothing about the machine. Clones on several machines are stale. One machine's
configuration — the original development VPS — lives outside this repository
altogether, which is why it cannot be reproduced from it. And the fleet's data
has a single provider and no test that it could be moved to another.

Four findings shape the answer, each with what establishes it:

1. **Nix's guarantee stops at the store boundary.** It builds an immutable tree
   and moves a pointer. It never reads the machine to decide what to do; it
   cannot diff, plan, or undo anything outside the store — login shells,
   sessions, secrets, `/etc/nix/nix.conf` on a non-NixOS host. Everything
   experienced as "not declarative" lives outside that boundary, and so does
   every line of shell in this repository. Investing in Nix means shrinking
   what is not Nix.
2. **Five of the seven registered profiles are standalone Home Manager on
   Ubuntu** — the host registry says so — which rules out every whole-system
   pull tool (comin, `system.autoUpgrade`, clan, colmena) as a fleet-wide
   mechanism, and makes the Ubuntu hosts the place where the shell residue
   accumulates.
3. **CI already builds full activation closures for two hosts and discards
   them** into a GitHub Actions cache no machine can read: the workflow builds
   the closures and names no substituter any machine trusts. The fleet's
   builder exists; its output has nowhere to go.
4. **The delightful installers are not delightful because of their language or
   a TUI.** Reading them says why: Omarchy is Bash; chezmoi is Go with no TUI.
   They share five mechanics: a plan that is a real object shown before
   anything runs; a receipt that makes uninstall the plan replayed backwards;
   questions batched up front and a run that is otherwise unattended; full
   output to a log with a bounded view on screen; and a `name: STATUS` recap at
   the end. This repository does the fourth and half of the first.

The constraints the decision must honour: a deep bet on Nix and NixOS as the
"can't fail" shape for an agent-driven world; everything self-hostable, so no
provider is load-bearing; `AGENTS.md` as the one standard for agent context,
never a tool-specific file maintained by hand; and large steps now rather than
small ones later, provided nothing becomes unusable in between.

## Decision

### The shape

The fleet is **three machines you can hold in your head**, plus templates for
machines that are not yours:

| Machine | Role | Platform |
| --- | --- | --- |
| `dev-01` | **workshop and services**: where development happens and where always-on services run, isolated by cgroup slice | NixOS (already) |
| MacBook Air | offline workshop and desktop | nix-darwin |
| Windows desktop / WSL | thin window and the Windows package surface | NixOS-WSL |

Everything else is decommissioned or becomes a template:

- The original development VPS (`platform-01`) is **left**, by a
  runbook, not a leap (see Roadmap step 0).
- The qualification VM (`tyrode-ci-01`) is **deleted**. CI is
  GitHub Actions; a NixOS generation is a better safety net than a VM run.
- **Client machines are not in this fleet.** A client's service is provisioned
  from a template (nixos-anywhere + disko, seeded from a RAM installer)
  by a flake that lives with the client's code, on a machine the client owns.
  The operator's *identity* on such a machine is the portable
  `development-*` profile, which already exists.

**Workshop and services on one box — decided.** The workshop is the machine
development happens on, the one built and broken deliberately; it also hosts
`manifold`'s hub. One box, two systemd slices (`services.slice` with a memory
floor, `workshop.slice` with a memory ceiling), so a development build can never
starve a service — the failure that originally drove the fleet to two boxes.
A separate small services box is earned only if a service's uptime ever
matters to *other people*; until then, one box.

### The substrate

Applications stop inventing cross-machine glue because the fleet provides it:

| Concern | Substrate | Replaces |
| --- | --- | --- |
| Configuration | one repository, this one, for every machine including the server; **clan** (clan-core, pinned) is the fleet layer inside it and `atyrode` the single front door that wraps it — *amended 2026-09-02, below* | a second repository carrying a second convergence engine |
| Secrets and their audience | **clan vars over sops-nix**: generators mint per-machine values encrypted to the machines that may read them; each machine mints its own age key on the machine and clan records only the public half; the operator's daily identity is hardware-bound in the Mac's Secure Enclave and the existing software key is the recovery recipient — *amended 2026-09-02* | the Bitwarden ceremony, `vault.sh`, provisioning ceremonies that only existed to fetch a value, hand-encrypted `secrets/*.yaml` |
| Identity and reachability | plain WireGuard through clan's `wireguard` service: controller on the workshop, peers elsewhere, keys and addresses generated, never typed — *amended 2026-09-02* | SSH key distribution, per-app auth protocols, a hand-written peer list |
| Built artifacts | CI builds every host closure and pushes to a **Cellar** bucket (already paid for, S3 to write, plain HTTPS to read, no server) | every machine rebuilding what CI already built |
| Agent context | a **generated** `AGENTS.md` deployed by this repository to every machine (see below) | telling every agent on every machine what is authenticated where |
| Data | restic to Cellar continuously (the upstream NixOS module), and clan's `localbackup` service for the **disk at home** on a routine the fleet enforces (below) — *amended 2026-09-02* | a per-project backup story |

**Sessions are values.** Most "logins" (`clever`, `gh`, Cellar keys) produce a
token that is a string; captured once, it is a secret with an audience like any
other. The only device-bound session in the fleet is Bitwarden's, and it leaves
the daily path: Bitwarden becomes the break-glass copy of the operator's
recovery age identity, a value read by hand once and never by a timer.

**Two operator identities, decided.** The key the operator edits secrets with
day to day lives in the Mac's Secure Enclave (`age-plugin-se`, Touch ID on
every edit) and cannot be copied off it; the software key that exists today
becomes the recovery recipient, its only copy the Bitwarden note. Losing the
Mac costs a re-encryption with the recovery key and rotates nothing, because
nothing could have left the enclave. The cost accepted is that secrets are
edited from the Mac.

**Publishing ciphertext is decided.** `secrets/*.yaml` is age-encrypted to
named recipients; a reader of the public repository learns the *names* of
secrets and *which machines* may read them, never the values. A leaked machine
key means rotating the values that key could read, exactly as a leaked vault
session would. A private secrets flake input remains the hedge if that ever
changes, at the cost of one more repository.

**Clever Cloud is the hosting fallback while the fleet matures.** Self-hosting
is the target and waits on one capability: the fleet must be able to provision
a machine, verify it is healthy, and hold it to a role. Until that exists,
services whose uptime is promised may live on Clever Cloud, whose costs are
kept deliberately modest.

**No provider is load-bearing.** Every external service is used through a
standard interface (S3, Postgres, HTTP) with credentials in sops and endpoints
in inventory, so leaving a provider is a configuration change; and every such
service has a NixOS equivalent the workshop can run. The exit test, checked by
`doctor`: *can the fleet stand up the self-hosted equivalent in one apply, and
is the data restorable from a backup that does not live with the provider?*

### Backups that do not depend on remembering

The first target is Cellar, continuous and unattended. The second is a disk
at home, chosen because it is truly independent of every provider — and it
cannot be unattended, because a disk has to be plugged in. So the routine is
designed around the one human step instead of hoping for a habit: the machine
that sees the disk **starts the backup itself** the moment it is attached
(udev on Linux, a launchd watcher on the Mac), records the completion in a
stamp the fleet can read, and `doctor` turns an overdue stamp into a loud,
persistent, specific nag — in the login shell, in `manifold`, and as a
desktop notification — that says exactly which disk to plug into which
machine. The only human step is plugging the disk in; the fleet does the
remembering, the starting, and the nagging.

### The flow

Green `main` is the event that matters, so it is what moves machines:

1. A release of a fleet tool (`code`, `babel`, `omp`) **dispatches** the
   dotfiles pin bump the moment it publishes, instead of waiting for a cron.
2. CI builds every host closure, pushes it to the cache, and on green `main`
   **pushes** a converge to every reachable machine over the overlay.
3. A **slow timer** on every machine is the floor for machines that were
   asleep; it converges only to revisions CI has built, and never a dirty
   checkout (`self ? rev`).
4. `atyrode fleet apply` is the manual "now", from any machine.
5. `doctor` reports drift (deployed revision against `origin/main`) and the
   login shell says so.

The latency floor becomes CI itself, which is the next thing to attack.

### Agent context

`AGENTS.md` is the standard. This repository's `AGENTS.md` holds *its* rules.
The facts an agent needs about *a machine* — what is authenticated here, which
secrets are readable, where the canonical clones are, which host this is and
what the others are called, the cross-repository invariants — are machine
state, not repository state, and are **generated** by `atyrode` from `doctor`
at activation into one `AGENTS.md` that this repository deploys to every
machine. Tool-specific files (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) are
symlinks to it, never maintained. This repository's own `AGENTS.md` states that
propagation is its job and must be kept true.

### Naming

One name per machine, used everywhere: host registry key, hostname, overlay
name, `manifold` label, `doctor` output. **Decided:** servers keep the cattle
form `tyrode-<role>-NN`; personal devices take `alex-<form>` (`alex-air`,
`alex-desk`); architecture and platform stay fields in the registry, never
part of a name.

### The overlay network

Four overlays were compared before the choice, because an earlier preference
for NetBird or plain WireGuard over Tailscale carried no recorded reason. The
facts, as of this record:

| | Client | Control plane | Identity | Self-host |
| --- | --- | --- | --- | --- |
| Tailscale | open (BSD-3) | **proprietary**, US-hosted; $275M VC | Google/Microsoft/GitHub/passkey SSO only | only via Headscale, a community reimplementation |
| Headscale + Tailscale client | open | open (BSD-3), self-hosted, volunteer-maintained | punts | first-class, ~30 MB RSS |
| NetBird | open | **open (BSD-3 → AGPLv3)**, Berlin, €8.5M Series A | any OIDC | first-class, single binary since 0.65; NixOS module exists |
| plain WireGuard | in-kernel | none | keys | it *is* self-hosted; NixOS `networking.wireguard` |

The preference turns out to have a rational basis: Tailscale is the one option
whose brain is closed and whose identity is delegated to a large US provider,
which is at odds with "no provider is load-bearing". **Decided: plain
WireGuard, hub-and-spoke through the workshop, keys in sops, peers in Nix** —
forty lines, no third party, entirely inside the reliable ring, and exactly
the case it was designed for. CI never joins the overlay: it
reaches the workshop's public address with a deploy key held in CI, and the
workshop fans out to the spokes. If SSO, ACLs or a mesh are ever wanted, NetBird
self-hosted is the upgrade path with the same properties. Tailscale is not
wrong; it is the least aligned with the constraints above.

### Presentation

`pkgs/atyrode-tui` — a 5,880-line Bubble Tea cockpit on `cli-kit`, launched by
bare `atyrode` on a terminal — becomes the **front door**. The bootstrap shell
shrinks to the smallest thing that can install Nix (the Determinate installer,
which owns `plan`, receipt, `repair` and `uninstall`), clone, register the
machine's age key, and enter the cockpit. The three missing mechanics — a plan
that is an object with a receipt, questions batched up front, an end-of-run
recap — land in the Bash engine as `--json` contracts the cockpit renders. The
engine is not rewritten; it shrinks. `narrate.sh` stays as the voice of what
remains and receives no further investment.

### What is deleted, and how success is measured

Success is measured in lines removed. Expected deletions once the substrate
exists: `vault.sh`; the provisioning ceremonies that only fetched values;
`install.sh`'s nine detect/repair pairs (the Determinate installer owns them);
`infra.sh`; the fleet half of the separate server repository (its server,
disko recipe and clan declaration come here; its RAM installer seeds the
client template); every clone on a machine that is a window rather than a
workshop.

## Consequences

- Sync, secrets and unattended operation are **one decision**: a timer cannot
  type a master password but can read a file. Adopting sops-nix is what makes
  push-on-green and the converge floor possible at all.
- The server joins this repository, so the two-repository courier chain and
  its orphaned-SHA hazard end. The prod boundary that mattered — "CI built and
  tested this revision" — is now the cache itself.
- The repository becomes the only place configuration, secrets audience,
  peers, backups and agent context are written; every machine is a projection.
  Copying anything between machines is a smell.
- Every machine must pass the **fifteen-minute test**: destroy it, re-provision
  from this repository, and be working again. A machine that fails the test
  names exactly what is not yet in Nix, sops or a backup.
- The Ubuntu hosts stop being a category: the original one is left, and the
  portable profile remains for machines that are not the operator's.

## Roadmap

Each step leaves the fleet usable. Steps marked **open** wait for the operator.

0. **Leave the original development VPS by runbook, not by leap.** An agent
   produces a read-only inventory of the machine: every git checkout and
   whether it is pushed, stashes and untracked files, dotfiles not in this
   repository, credentials under `~/.config` and `~/.local`, environment
   files, user services and timers, containers and volumes, databases,
   anything under `/srv`, `/opt`, `/var` that is not the OS. Every item is
   classified — *in git and pushed / needs pushing / secret → sops / data →
   backup / OS / junk* — into a manifest the operator reviews. Nothing is
   deleted until the manifest shows every secret has a new home **and** a
   full restic snapshot of the classified data exists at a target that is not
   the machine. The snapshot is kept for ninety days after the server is
   cancelled. The inventory exists because a machine outside this repository
   is the one place a secret can sit unrecorded, and no leap can prove that
   none does.
1. **Cache and CI as builder.** Cellar bucket (created with the authenticated
   `clever` CLI), signing key in CI, every host closure built and pushed,
   `doctor` and the system-boundary check extended to the second substituter.
   Closes the "CI never built the Darwin system" gap for good.
2. **Generated agent context.** `atyrode` renders the machine `AGENTS.md`
   from `doctor` at activation; this repository deploys it and the tool
   symlinks. This repository's own `AGENTS.md` is written at the same time.
3. **Secrets.** *(amended 2026-09-02)* The repository is restructured first
   (below), then becomes a clan whose machines are the workshop, the Mac and
   WSL; each machine mints its own age key and clan records the public half;
   the operator's two identities are registered as clan users; the first
   surface moves (`git-identity`) as a clan var, then `clever` and Cellar
   tokens as values, then babel. Each surface leaves Bitwarden only when its
   clan path works; `vault.sh` dies last.
4. **Overlay and flow.** *(amended 2026-09-02)* clan's `wireguard` service
   with the workshop as controller, push-on-green from CI, the converge
   floor, `atyrode fleet apply` wrapping `clan machines update`, drift in
   `doctor` and the shell.
5. **The server joins this repository.** *(amended 2026-09-02)* `dev-01`
   moves in as a clan machine with its disko, boot, network and policy
   modules (about a thousand lines); its public address becomes a value, not
   a literal, because this repository's lint refuses address literals. What
   remains of the separate server repository is the runner platform, whose
   fate is open (below). `tyrode-ci-01` is deleted.
6. **Delete.** Ceremonies, `vault.sh`, `install.sh` repairs, `infra.sh`,
   stale clones; measure the diff.
7. **Front door.** Bootstrap enters the cockpit; plan/receipt/recap land as
   `--json`; the shell engine keeps shrinking behind it.

## Amendment 2026-09-02: clan is the fleet layer, and the repository is reshaped

The record as accepted implied dropping clan: folding the separate server
repository into this one carried "clan goes" without saying so. Re-examined
against the fleet this record is heading toward rather than today's three
machines, the implication reverses.

**Why clan.** The target fleet is self-hosted and larger than three machines:
a backup host, service hosts, machines that come and go. At that size the
thing that scales is not the module system, which NixOS already provides, but
**per-machine generated secrets and role-based inventory**: adding a machine
must be one declaration and one command, not a round of hand-generated keys,
hand-edited peer lists and `sops updatekeys`. The alternative to clan at eight
machines is writing clan badly — a homegrown roles-and-secrets library, which
is exactly the shape of the separate server repository and the failure this
record exists to end. Clan is also not a stranger's stack: its inputs are
sops-nix, disko, nix-darwin and nixpkgs, the very primitives the first version
of this record proposed composing by hand, and its maintainers are theirs. Its
service catalog (wireguard with generated keys and address allocation,
localbackup, sshd, trusted caches, emergency access, users) maps onto the
substrate table row by row, and its role model
(controller/peer, hub/agent) is the shape `manifold` has.

**Measured before deciding.** The existing consumer uses two of clan's
generators and none of its services; that is an argument about the past, not
the future, and it was set aside. Two risks were verified in clan's source at
the pinned revision: vars and secrets deploy on the darwin class (the same
clanCore and sops-nix darwin module; unverified on real hardware, which the
Mac's first update will settle), and the operator's Secure Enclave identity is
accepted (the key-file parser takes `AGE-PLUGIN-*` lines behind the recipient
comment the plugin writes; all crypto is delegated to the `sops` binary). A
spike folded the Mac and WSL into a clan on a branch: the NixOS-WSL toplevel
derivation is byte-identical to `main`, the Darwin system differs only in the
order of an unchanged package list, vars evaluate on both classes, the lock
grows by six nodes, evaluation costs one to three seconds, and clan's
"recommended defaults" (extra packages, networkd, mDNS, a hostId) are taken
back in four lines so policy stays this repository's.

**What clan does not do, accepted.** It is push-only; the converge floor and
push-on-green stay this repository's. Its darwin support is young: the machine
class exists, one service is darwin-aware. Standalone Home Manager hosts are
invisible to it, which under this record is fine. It is pre-1.0 and carries
deprecation notices; the pin bot and a red pull request are the tax. Its
default machine-key flow copies a private key over SSH; the fleet takes the
path clan tolerates instead — the machine mints its key, clan records the
public half — so no private key ever travels.

**The repository is reshaped first.** The same sweep restructures this
repository by role rather than by tool, so the fold lands on a clean layout
instead of adding to the mess: `bootstrap/`, `fleet/`, `modules/{nixos,darwin,
home,shared}`, `pkgs/`, `checks/` grouped by subject, `ci/`, `docs/`,
`secrets/`, `lib/`. The rules that keep it that way are `AGENTS.md`'s.

**Plaintext never reaches a remote.** Publishing ciphertext is safe by design
and topology is public anyway; the residual risk is a value pasted by hand.
A pre-commit hook on every machine scans the staged diff of every repository
with gitleaks, and the same scanner is a whole-tree lint in CI, which also
refuses any unencrypted file under `secrets/`.

**Open, with a date.** The other 97% of the separate server repository is a
self-hosted CI runner platform (ARC on Kubernetes, Clever fleet runners,
brokers, a qualification VM) that only the deleted `tyrode-ci-01` consumed.
Whether it lives as its own product repository or is archived is **decided
after the server has moved**, by 2026-10-01, and is recorded as decision 10
below when it is. Its GitHub App broker — short-lived, repository-scoped
tokens minted for local users — is the one platform piece with a fleet use and
is evaluated then.

## Decisions

1. One box with two slices — **yes**, because two systemd slices with a memory
   floor and a memory ceiling stop a development build starving a service,
   which is the only thing the second box ever bought.
2. Naming — **`tyrode-<role>-NN` for servers, `alex-<form>` for devices**, with
   architecture and platform as registry fields, never part of a name.
3. Ciphertext — **in this repository, encrypted**, because a reader learns only
   the names of secrets and which machines may read them, and a private input
   costs one more repository for nothing.
4. Second backup target — **a disk at home**, because it is independent of every
   provider, with the routine designed so the fleet starts the backup and nags
   for it and the only human step is plugging in.
5. Step 0's inventory — **begun immediately**, read-only, producing a manifest
   for review, because nothing may be deleted before every secret has a new
   home.
6. Where the operator's key lives — **the Mac's Secure Enclave**, with the
   existing software key as recovery, because a key that cannot be copied off
   the hardware turns a lost device into a re-encryption rather than a
   rotation. *(Revised by the sub-amendment below.)*
7. The unpushed `manifold` work — **stays on the old box for now**; the
   runbook lists it as the first thing that must leave before anything is
   deleted.
8. Clan's place, decided for the target fleet rather than today's three
   machines — **build on clan, folded into this repository**, with `atyrode` as
   the front door, because the alternative at eight machines is a homegrown
   roles-and-secrets library.
9. The repository's shape — **restructured by role**, in one move, before the
   fold, so the fold lands on a clean layout instead of adding to the mess.
10. The runner platform's fate — **open**, decided after the server has moved,
    by 2026-10-01, because only the deleted qualification VM consumed it and
    the fleet has no other claim on it yet.

### Sub-amendment 2026-09-02: one operator key per device

Decision 6 is revised. The operator's identity is **one clan user per operator
device** (`alex-<host>`), every one a member of the `admins` group
that every value is encrypted to, plus `alex-recovery` in Bitwarden. The
Mac's key is Secure Enclave-backed because that hardware exists there, and
it grants nothing the others lack; a Linux device's key is a plain age file.
Nothing about the fleet depends on any one device, which is what "the Mac's
Secure Enclave" had quietly undone.

Machine keys follow **clan's default**: `clan vars generate` mints a
machine's key on an operator device and keeps its private half in the
repository encrypted to the group; `atyrode apply` places it on the machine
the operator sits on and `clan machines update` on one reached over SSH.
The mint-on-machine ceremony (`atyrode identity init`) is deleted: whoever
holds the operator key can already read every value, so a machine key
encrypted to that same key added nothing but a ceremony, and a rebuilt
machine now needs no re-registration.

