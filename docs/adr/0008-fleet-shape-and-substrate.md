# ADR 0008: Fleet shape, substrate, and the road there

- Status: Proposed
- Date: 2026-09-01
- Supersedes: [0005](0005-no-declarative-secret-manager.md) — its stated
  trigger ("a concrete secret must be delivered declaratively") has fired.

This record is written to be read slowly and annotated. It lives in a public
repository, so it names roles and machines, never providers, prices, addresses
or keys. Every choice below is
either **decided** or explicitly **open**, and nothing marked open is built
until the operator closes it. The fleet stays usable at every step of the
roadmap; no step may leave a machine that cannot converge.

## Context

The repository grew into a platform run by one person: a fleet of machines, a
9,800-line Bash CLI with its own convergence model, a second convergence model
in `install.sh`, three agent tools that each carry a little cross-machine glue
(`code`, `babel`, `manifold`), a production server managed from a separate
9,500-line repository, and secrets fetched by hand from Bitwarden on every
machine. The operator's reported pains, in his words and in the order they
surfaced: bootstrap output is "a long chain of commands and yes/no questions";
machines drift out of sync and switching between them hurts; an `omp` release
costs two repositories, two CI waits and four manual applies; secrets are
"breadcrumbs everywhere" with Bitwarden as the glue; agent context is lost on
every project and every machine; clones on several machines are stale; the
original development VPS is debt he is afraid to leave; data held with a
provider makes him anxious about the day that provider is no longer an option. Underneath all of it: maintenance fatigue.

Four facts established by research in this session shape the answer:

1. **Nix's guarantee stops at the store boundary.** It builds an immutable tree
   and moves a pointer. It never reads the machine to decide what to do; it
   cannot diff, plan, or undo anything outside the store — login shells,
   sessions, secrets, `/etc/nix/nix.conf` on a non-NixOS host. Everything the
   operator feels as "not declarative" lives there, and so does every line of
   shell in this repository. Investing in Nix means shrinking what is not Nix.
2. **Five of the seven registered profiles are standalone Home Manager on
   Ubuntu**, which rules out every whole-system pull tool (comin,
   `system.autoUpgrade`, clan, colmena) as a fleet-wide mechanism, and makes
   the Ubuntu hosts the place where the shell residue accumulates.
3. **CI already builds full activation closures for two hosts and discards
   them** into a GitHub Actions cache no machine can read. The fleet's builder
   exists; its output has nowhere to go.
4. **The delightful installers are not delightful because of their language or
   a TUI.** Omarchy is Bash; chezmoi is Go with no TUI. They share five
   mechanics: a plan that is a real object shown before anything runs; a
   receipt that makes uninstall the plan replayed backwards; questions batched
   up front and a run that is otherwise unattended; full output to a log with a
   bounded view on screen; and a `name: STATUS` recap at the end. This
   repository does the fourth and half of the first.

The operator's stated values, which the decision must honour: a deep bet on Nix
and NixOS as the "can't fail" shape for an agent-driven world; everything
self-hostable so no provider is load-bearing; `AGENTS.md` as the one standard
for agent context, never a tool-specific file maintained by hand; big bites now
over small ones later, provided nothing becomes unusable in between; and every
decision taken with him, not for him.

## Decision

### The shape

The fleet is **three machines you can hold in your head**, plus templates for
machines that are not yours:

| Machine | Role | Platform |
| --- | --- | --- |
| `tyrode-dev-01` | **workshop and services**: where development happens and where always-on services run, isolated by cgroup slice | NixOS (already) |
| MacBook Air | offline workshop and desktop | nix-darwin |
| Windows desktop / WSL | thin window and the Windows package surface | NixOS-WSL |

Everything else is decommissioned or becomes a template:

- The original development VPS (`alex-x86_64-linux`) is **left**, by a
  runbook, not a leap (see Roadmap step 0).
- The qualification VM (`tyrode-ci-01`) is **deleted**. CI is
  GitHub Actions; a NixOS generation is a better safety net than a VM run.
- **Client machines are not in this fleet.** A client's service is provisioned
  from a template (nixos-anywhere + disko, seeded from infra's RAM installer)
  by a flake that lives with the client's code, on a machine the client owns.
  The operator's *identity* on such a machine is the portable
  `development-*` profile, which already exists.

**Open — workshop and services on one box.** The workshop is the machine the
operator wants to build and break things on; it also hosts `manifold`'s hub.
Decided: one box, two systemd slices (`services.slice` with a memory floor,
`workshop.slice` with a memory ceiling), so a development build can never
starve a service — the failure that originally drove the fleet to two boxes.
Open: whether any service's uptime matters to *other people* enough to earn a
separate small box later. Until it does, one box.

### The substrate

Applications stop inventing cross-machine glue because the fleet provides it:

| Concern | Substrate | Replaces |
| --- | --- | --- |
| Configuration | one repository, this one, for every machine including the server | `tyrode-dev/infra` as a second engine |
| Secrets and their audience | **sops-nix**, age keys, `secrets/*.yaml` with `.sops.yaml` audience groups; the operator's existing age identity spans it | the Bitwarden ceremony, `vault.sh`, provisioning ceremonies that only existed to fetch a value |
| Identity and reachability | plain WireGuard, hub-and-spoke through the workshop, keys in sops, peers in Nix | SSH key distribution, per-app auth protocols |
| Built artifacts | CI builds every host closure and pushes to a **Cellar** bucket (already paid for, S3 to write, plain HTTPS to read, no server) | every machine rebuilding what CI already built |
| Agent context | a **generated** `AGENTS.md` deployed by this repository to every machine (see below) | telling every agent on every machine what is authenticated where |
| Data | restic to two targets, declared as a NixOS service | a per-project backup story |

**Sessions are values.** Most "logins" (`clever`, `gh`, Cellar keys) produce a
token that is a string; captured once, it is a secret with an audience like any
other. The only device-bound session in the fleet is Bitwarden's, and it leaves
the daily path: Bitwarden becomes the break-glass copy of the operator's age
identity, the role it already plays for infra today.

**Publishing ciphertext is accepted.** `secrets/*.yaml` is age-encrypted to
named recipients; a reader of the public repository learns the *names* of
secrets and *which machines* may read them, never the values. A leaked machine
key means rotating the values that key could read, exactly as a leaked vault
session would. If publishing ciphertext ever becomes uncomfortable, a private
`atyrode/secrets` flake input is the hedge, at the cost of one more repository.

**Clever Cloud is the hosting fallback while the fleet matures.** The operator
would rather self-host everything, and will, once the fleet can provision a
machine, verify it is healthy and hold it to a role. Until then, services that
must stay up may live on Clever Cloud in the Tyrode organisation, with costs
kept deliberately modest; that is what the credits are for.

**No provider is load-bearing.** Every external service is used through a
standard interface (S3, Postgres, HTTP) with credentials in sops and endpoints
in inventory, so leaving a provider is a configuration change; and every such
service has a NixOS equivalent the workshop can run. The exit test, checked by
`doctor`: *can the fleet stand up the self-hosted equivalent in one apply, and
is the data restorable from a backup that does not live with the provider?*

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
name, `manifold` label, `doctor` output. **Open:** the scheme. Proposed:
servers keep infra's cattle form `tyrode-<role>-NN`; personal devices take
`alex-<form>` (`alex-air`, `alex-desk`); architecture and platform stay fields
in the registry, never part of a name.

### The overlay network

The operator recalls disliking Tailscale and preferring NetBird or plain
WireGuard, without recalling why. The facts, as of this record:

| | Client | Control plane | Identity | Self-host |
| --- | --- | --- | --- | --- |
| Tailscale | open (BSD-3) | **proprietary**, US-hosted; $275M VC | Google/Microsoft/GitHub/passkey SSO only | only via Headscale, a community reimplementation |
| Headscale + Tailscale client | open | open (BSD-3), self-hosted, volunteer-maintained | punts | first-class, ~30 MB RSS |
| NetBird | open | **open (BSD-3 → AGPLv3)**, Berlin, €8.5M Series A | any OIDC | first-class, single binary since 0.65; NixOS module exists |
| plain WireGuard | in-kernel | none | keys | it *is* self-hosted; NixOS `networking.wireguard` |

The dislike has a rational basis: Tailscale is the one option whose brain is
closed and whose identity is delegated to a large US provider, which is at odds
with "no provider is load-bearing". **Decided: plain WireGuard, hub-and-spoke through the workshop, keys in sops,
peers in Nix** — forty lines, no third party, entirely inside the reliable
ring, and exactly the case it was designed for. CI never joins the overlay: it
reaches the workshop's public address with a deploy key held in CI, and the
workshop fans out to the spokes. If SSO, ACLs or a mesh are ever wanted, NetBird
self-hosted is the upgrade path with the same ethics. Tailscale is not wrong;
it is the least aligned with the values above.

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
`infra.sh`; `tyrode-dev/infra` down to its installer and disko recipe, which
become the client template; every clone on a machine that is a window rather
than a workshop.

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

0. **Leave the original development VPS by runbook, not by leap.** An agent produces a
   read-only inventory of the machine: every git checkout and whether it is
   pushed, stashes and untracked files, dotfiles not in this repository,
   credentials under `~/.config` and `~/.local`, environment files, user
   services and timers, containers and volumes, databases, anything under
   `/srv`, `/opt`, `/var` that is not the OS. Every item is classified —
   *in git and pushed / needs pushing / secret → sops / data → backup / OS /
   junk* — into a manifest the operator reviews. Nothing is deleted until the
   manifest shows every secret has a new home **and** a full restic snapshot
   of the classified data exists at a target that is not the machine. The
   snapshot is kept for ninety days after the server is cancelled. This step
   is the answer to "I am afraid I forgot a secret somewhere".
1. **Cache and CI as builder.** Cellar bucket (created with the authenticated
   `clever` CLI), signing key in CI, every host closure built and pushed,
   `doctor` and the system-boundary check extended to the second substituter.
   Closes the "CI never built the Darwin system" gap for good.
2. **Generated agent context.** `atyrode` renders the machine `AGENTS.md`
   from `doctor` at activation; this repository deploys it and the tool
   symlinks. This repository's own `AGENTS.md` is written at the same time.
3. **sops-nix.** Operator identity registered, one recipient per remaining
   machine, `.sops.yaml` audiences, the first surface moved (`git-identity`),
   then `clever` and Cellar tokens as values, then babel. Each surface leaves
   Bitwarden only when its sops path works; `vault.sh` dies last.
4. **Overlay and flow.** WireGuard peers in
   Nix, push-on-green from CI, the converge floor, `atyrode fleet apply`, drift
   in `doctor` and the shell.
5. **The server joins this repository.** `tyrode-dev-01` as a
   `nixosConfiguration` with slices; `infra` shrinks to installer + disko and
   becomes the client template; `tyrode-ci-01` is deleted.
6. **Delete.** Ceremonies, `vault.sh`, `install.sh` repairs, `infra.sh`,
   stale clones; measure the diff.
7. **Front door.** Bootstrap enters the cockpit; plan/receipt/recap land as
   `--json`; the shell engine keeps shrinking behind it.

## Open questions for the operator

1. Workshop and services on one box with two slices — accepted, or do you want
   a separate small services box from the start?
2. Naming scheme: `tyrode-<role>-NN` for servers and `alex-<form>` for
   devices, or something you would rather type every day?
3. Ciphertext in the public repository, or a private secrets input?
4. Backup targets: Cellar plus which second, provider-independent target
   (an object store at a second provider, or a disk at home)?
5. May step 0's read-only inventory of the old development machine begin? It changes
   nothing and answers the fear.
