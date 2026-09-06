# The `atyrode` CLI

`atyrode` is the one front door to a machine: it applies and inspects these
dotfiles from the registry in [Hosts and capabilities](hosts.md) and wraps
`clan`, `nh` and `sops` so no machine needs a different command depending on
what it is. `atyrode --help` is the syntax reference and is not repeated here;
the commands of a normal week are in [Running the fleet](day-to-day.md). This
page records what the CLI promises: what `apply` may and may not do to a
running machine, what reaches the terminal, and where the identities and
surfaces it manages come from. Runtime capabilities (`atyrode runtime`) are a
separate, opt-in layer for large machine-local services that do not belong in
a Nix generation; applying the dotfiles never creates their state,
credentials, containers, or model downloads.

## Applying a configuration

The default host comes from a registered `ATYRODE_HOST`, then the managed host
identity file, then an unambiguous user/system/hostname match. Generated values
can outlive a rename in an existing login or user manager, so an unregistered
environment value requires a current managed identity or an exact hostname
match, never a guess from platform alone. An explicit host argument is
authoritative and an unknown one is refused. Apply resolves the host before
submitting its managed job and forwards that answer rather than rediscovering
it in the worker.

Without `--repo`, apply resolves the requested ref (default `main`) to an exact
commit with `git ls-remote`, so no checkout is involved and an apply
immediately after a merge selects that merge. A published CLI whose revision
differs first builds and invokes that commit's `atyrode`, before host
resolution or job submission: the target revision owns bootstrap, activation
and every follow-up probe, and the replaced CLI never interprets the new
generation. `--repo PATH` is for development -- activating work in progress
before pushing -- and additionally validates the checkout and reports a dirty
tree.

Read-only key inspection uses the CLI's packaged source, never an implicit
`~/nix-dotfiles` checkout. Commands that author repository state require an
explicit writable `--repo PATH`; normal apply does not become an authoring
operation when a required value is missing.

### The mutation boundary

Build and preview first produce an exact candidate closure. Activation
compares that closure against the current generation, including the Home
Manager units a system generation embeds, before any service stop is queued,
and switches the inspected store path rather than a newly evaluated branch. A
successful activation records the canonical host; failures and dry runs do not
touch that receipt.

The policy is `fleet/service-protection.json`. Session owners, SSH and Docker
are protected, and an owner can additionally declare
`X-Atyrode-SessionOwner`. Protected stops, restarts and reloads, unknown
effects, and changes outside an explicitly requested `--scope` refuse. A
retained owner (`keep`) stays running with its update pending.
`--expected-disruption` binds automation to a particular safe preview; it
cannot authorize a blocked report, and `--yes` is not a bypass. Apply,
rollback and every Manifold agent mutation hold the same activation lock,
including token rotation. A NixOS-global user unit is inactive only if every
live user manager proves it; an inaccessible manager is unknown, not evidence
of absence. Owner-to-transport role changes refuse while the old owner remains
loaded, even if this activation would retain it, because the next activation
must not inherit permission to kill a process that still owns sessions.

Context rendering re-enters the inspected candidate's CLI, never an unrelated
global profile. Runtime stop, restart and token rotation likewise compare the
deployed role with the loaded definition before acting, and rotation performs
that check before contacting the hub; the [Manifold migration
runbook](manifold.md#upgrades) names the deliberate initial maintenance
boundary. These checks prevent accidental disruption through supported tools,
not raw commands run outside them by an unrestricted account.

Activation success and apply completion are distinct. A failed requested
provisioning ceremony, login-shell convergence, timer start, or context render
produces a nonzero exit and an incomplete apply verdict, including in the
supervised job result. Optional surfaces left unconfigured are listed as
outstanding rather than labelled a complete apply; explicitly declining an
optional surface is not a failure.

### What the CLI shows while it runs

Every verb that changes this machine is a command an operator waits on, so it
narrates itself rather than going quiet between builds. Five things reach the
terminal.

**A plan first.** The steps that will change this machine, numbered, before
any of them run; `--plan` prints exactly that list and stops.

**The argv of anything that acts.** Every command that changes the machine,
reaches the network, prompts, or takes real time is printed before it runs,
shell-quoted so the line can be pasted back to repeat that step by hand, for
every mutating verb from the `nh` switch and the `git ls-remote` that resolves
a ref to each provisioning ceremony, every rollback, the Clan deployment of a
remote host and the `curl` that enrolls this machine with a fleet master.
Narration goes to stderr, leaving structured stdout usable with `--json` and
`--preview-json`. It is an action transcript, not shell tracing: `set -x`
would expose secret-bearing expansions and is not a verbosity mode.

Read-only probing stays silent, because printing every `command -v` would bury
the handful of commands that act. So does the shell's own bookkeeping -- a
`mkdir`, a `chmod`, the `mv` that installs a rendered file atomically -- and
where one of those writes something persistent, the path is named in prose
instead. Two commands are deliberately described rather than quoted:
`systemd-run` carries the machine's whole forwarded `PATH`, so the terminal
gets the unit name and the log gets the argv; and no announcement may print a
secret, so a credential travels in a file and what reaches the terminal is a
verb, an id, and a path.

**Whose password prompt it is.** nix-darwin and NixOS activate as root and the
backend elevates for that itself; the step says so before the backend runs,
so a `sudo` prompt never reads as the dotfiles asking for root out of nowhere.

**A verdict per step**, with the declaration or diagnosis that made it
necessary (`why fleet/system-boundary.json declares ...`). A step never ends in
silence, because a silent step is indistinguishable from a hung one, and a run
that aborts still owes a verdict on the steps it promised:

```
1/5 Rebuild and switch macbook through nh-darwin
  $ env LC_ALL=en_US.UTF-8 nh darwin switch ...
  failed nh-darwin did not complete, and nothing was activated: this machine is unchanged

2/5 Record macbook as the activated host
  not attempted
```

That verdict is read rather than guessed. The backend builds the closure
before it switches, so most failures there never reached the machine at all;
the profile link says which happened, and an exit code cannot.

**A durable log.** Every run of a mutating verb writes a timestamped, mode-600
transcript of the same story to
`$XDG_STATE_HOME/atyrode/logs/<UTC>-<verb>.log`, named in the closing summary
and again on any failure. The terminal is for the operator watching; the log
is for the diagnosis three weeks later. It is the same contract and file
layout as the bootstrap's own run log ([bootstrap.md](bootstrap.md#run-logs)),
because the two narrate the same machine. A supervised apply writes two, and
the pair is the chain: the submitting shell's `-apply.log` records the
handoff, including the `systemd-run` argv kept off the terminal, and the
worker's `-apply-job.log` records the run itself.

### Supervised applies

On Linux with a systemd user manager, a mutating apply runs in a transient
service so that replacing a terminal-hosting service cannot terminate the
activation; job metadata, output, and the atomic final result live under
`$XDG_STATE_HOME/atyrode/apply-jobs`, and the CLI exits with the activation's
own status. From a terminal the job is handed that terminal, so every prompt
is answerable in place; the trade is that the job ends with the terminal, and
its log records where the output went rather than a copy, so `apply-status`
cannot claim a transcript it never captured. Read-only plans and dry runs stay
terminal-bound, and platforms without a user manager keep the direct,
interactive activation path.

### After activation

Apply reports plain-omp settings that drifted from the seeded repository
defaults (see [Agent tools](agent-tools.md#seeded-plain-omp-defaults)) and,
on a terminal without `--json`, offers a per-key keep-or-reset review. Drift is
never resolved automatically; skipping the review keeps every local value.

Apply then reviews the provisioning surfaces this machine has left
unconfigured. Every surface is declared once in `fleet/provisioning.json` with
the command that configures it and what that command implies, and nothing on
a machine needs a session opened before a surface can be configured, because
every secret a surface needs is a clan var that activation placed. A surface
is therefore either *offered*, when the command is a ceremony this CLI owns
and runs here, or *told*, when the command runs on an operator device and this
machine only reports what it is owed (`clan vars generate HOST` there, then
apply). Accepting an offer runs exactly the command it named in this terminal,
so what apply does and what the operator would have typed are the same thing.
Declining a surface marked `declinable` is recorded per machine and per
surface, so it is not offered again -- asking twice is how a prompt becomes
noise -- and the way back in is the command the offer named, which clears the
record as a side effect of the surface becoming configured; declining any
other surface prints the reminder unchanged. Off a terminal both are stated
without a question, since there is nobody to answer. Babel readiness first
requires readable, nonempty storage, payload-key and repository-password
files: a previous success stamp cannot hide incomplete placement. Only then
does the probe judge whether an archive has ever succeeded or is older than
48 hours (see [Agent tools](agent-tools.md#session-archive)). None of this can fail the activation:
a machine that declines to provision is still a machine that activated.

When an accepted ceremony stops, the follow-up names the failure and remedy.
Machine-key generation
requires `atyrode provision machine-key --repo PATH`; apply does not guess a
writable checkout and repeat the same failed ceremony.

### What is waiting on main

`atyrode changelog` compares the revision this CLI was built from with the
head of `main` (one `git ls-remote`), then reads GitHub's compare and
check-runs for the commit list and whether `ci-gate` passed: green means every
system and closure built and the fleet cache holds them, so `apply` downloads
rather than builds. Offline it says so rather than guessing; a development
build has no revision to compare and refuses. Nothing is activated: an update
is a prompt, and `atyrode apply` is the answer. `--record` writes
`~/.local/state/atyrode/update.json`, and every new interactive shell on a
terminal prints one muted line from that record while it names a revision this
CLI is not, on every shell until the machine runs `main`; `doctor
provisioning` reports the same drift under `convergence`. The hourly timer and
the shell hook are declared in
[`modules/home/atyrode`](../modules/home/atyrode/default.nix).

## Deploying another machine

`apply` converges the machine it runs on; `fleet apply` transfers an exact
built closure and asks the target's CLI to preview its local transition. Only
a safe report permits vars upload and fingerprint-pinned activation of that
same candidate, and after activation the machine is asked who it is, so a
deployment that activated the wrong closure fails there rather than exiting
zero. The target needs no checkout. Both verbs refuse a machine clan does not
deploy -- a portable profile has no system closure -- and say which command
converges it instead; the run stops before touching the machine when its vars
are not generated (the remedy names `clan vars generate <host>`) or when it
does not answer a strict-host-key check.
The initiating operator explicitly selects the checkout with `--repo PATH`;
the plan reports its revision and whether it is dirty.

Deploying reaches outside this repository for nothing: the machines are this
flake's, the operator identity is the device's own age key rather than a
session opened per run, and where a machine is reached is its own
`clan.core.networking.targetHost` rather than a separate enrollment
inventory.

## Agent context

Every agent on a machine starts from one file: the operator policy kept in
`modules/home/agents/AGENTS.md`, followed by a generated `## This machine`
section. `context render` writes it whole and moves it into place, and Home
Manager makes every tool's instruction file an out-of-store symlink to it, so
every tool reads the same bytes and none is maintained by hand. Activation
renders it (`modules/home/agents/default.nix`) and `atyrode apply` renders it
again as its last step, after the provisioning review may have changed what is
authenticated, so the file describes the machine apply leaves behind. This is
[ADR 0008](adr/0008-fleet-shape-and-substrate.md) step 2 and invariant 9 of
the repository's own `AGENTS.md`.

The generated section is machine state, never a value: the revision the CLI
came from and when it rendered, this host and the other registered ones, which
CLIs are authenticated here and as whom with the exact command that acquires
each missing session, the clan vars under `/run/secrets/vars` this account can
read by name and path, the fleet cache and whether the Nix daemon trusts it,
and the canonical clone root -- which no registry field declares yet, so the
section says so rather than guess.

`doctor provisioning` carries the matching `agent-context` surface: `ok` when
the file is fresh, `degraded` with remediation `atyrode context render` when
it was rendered from another published revision than the running CLI, is
older than seven days, or carries no generation stamp, and `incomplete` when
it is absent. The file is never edited by hand: if it is wrong, `doctor` is
wrong.

## Identities

Two age keys pass through the CLI and neither is ever printed, placed in argv,
or written to the run log. The **machine key** is the one clan vars are
decrypted with at activation, this machine's own and never the operator's;
`clan vars generate <host>` mints it on an operator device and `apply` places
it before the switch, so the activation
that follows decrypts the machine's vars. `provision machine-key --repo PATH`
is the same generation run from the machine itself when it is an operator
device, and the only `provision` verb. The **operator identity** is the key that edits
secrets, one per device, minted where it is used (inside the Secure Enclave on
a Mac) by `operator init`, which never replaces an existing
`~/.config/sops/age/keys.txt`; both `operator` verbs refuse on a portable
profile with exit 65, and the platform branch reads the registry's system
rather than `uname`, so its branch is exercised from a Linux sandbox.
`apply` offers operator identity initialization when needed, but leaves
machine-key authoring to an explicit checkout. `doctor provisioning`
carries them as the `machine-key` and `operator-identity` surfaces
(`not-applicable` on a portable profile; `incomplete` with no key; `degraded`
when the key exists but is not placed, or not registered, with the exact
commands as the remedy; `ok` otherwise). The custody model, both enrolment
ceremonies step by step, and what a lost device costs are in
[secrets.md](secrets.md).

## Inspection and diagnostics

The Git identity has no verb of its own: its authentication and signing keys
are a clan var generated on an operator device and placed by activation, and
Git and `ssh` read them directly; `doctor provisioning` reports the
`git-identity` surface as `not-applicable` on a portable profile, `degraded`
while the key is not placed (with `clan vars generate <host>` on an operator
device, then `atyrode apply`, as the remedy), and `ok` once it is. The custody
model is in [secrets.md](secrets.md#git-identity).

Managed `local-qwen` OMP processes hold independent session leases. Ten
minutes after the final session closes, the WSL idle reaper verifies that vLLM
has no active or queued requests and no new token activity, then stops the
container and releases its GPU memory. A new session or direct API activity
resets the deadline; stale leases from crashed processes are discarded.
`manifold-agent` joins the machine to the self-hosted manifold hub declared in
`fleet/manifold.json`; enrollment, upgrade discipline, replacing an unmanaged
agent, and the master-migration runbook live in [manifold](manifold.md).

Diagnostics use stable non-zero exits for invalid input, missing files or
tools, identity mismatches, and activation failure, and never expose
credentials. `doctor system` audits the boundary that package installation
alone cannot satisfy, including on macOS the residue of an interrupted or
superseded Nix installation: that is the state
[`bootstrap/install.sh`](../bootstrap/install.sh) repairs before Nix exists,
so repair stays in the installer while detection is shared, and a machine that
installed successfully years ago is re-examined on every `atyrode doctor` and
told which command repairs what it carries. Its check IDs, row schema,
statuses, exits, and read-only probe contract are in [Home Manager and system
boundary](system-boundary.md). `doctor git` separately audits author identity,
signing trust, SSH key selection, forge protocols, credential helpers and
`gh` token storage. It stays offline unless invoked as `atyrode doctor git
--online`, which checks the selected authentication key against the `gh`
account's GitHub registrations. An unavailable or malformed API response is
unknown, never proof that registration is missing. Custom SSH commands are
not executed. `failed` checks return 69; `warning` rows remain visible without
failing the report. JSON contains classifications, paths and fingerprints,
never key material, tokens, helper arguments or remote URLs. See
[secrets.md](secrets.md#git-identity) for the diagnostic boundaries.

With `--online`, the token-storage check may also ask `gh auth status` about
github.com; offline it only inspects local files and environment metadata.
