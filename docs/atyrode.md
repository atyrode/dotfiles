# The `atyrode` CLI

`atyrode` is the shared, packaged interface for applying and inspecting these
dotfiles. It reads the declarative registry described in [Hosts and
capabilities](hosts.md); it does not infer a profile from the current directory
or maintain a second mutable profile database.

Runtime capabilities are a separate, opt-in layer for large machine-local
services that do not belong in a Nix generation. `atyrode runtime` can inspect,
provision, start, and stop them; simply applying these dotfiles does not create
their state, credentials, containers, or model downloads.

## Interactive cockpit

Running bare `atyrode` with both stdin and stdout attached to a terminal opens
the interactive cockpit. A bare non-TTY invocation continues to print CLI help,
and every explicit subcommand (`atyrode apply`, `atyrode doctor …`, JSON calls,
and the other command surfaces) continues through the Bash CLI even on a TTY.
Existing scripts therefore do not enter the cockpit.

The apply panel first resolves the requested branch to an exact commit, then
loads both `atyrode apply --ref <commit> --preview-json` and `atyrode inventory
--ref <commit> --json` asynchronously. Its default activation preview
summarizes package, store-path, and closure-size changes without showing raw
generation paths; `d` toggles normalized technical details, where the previous
and new generation paths remain available with labels.

Press `c` to open or focus the active capability inventory. `[`/`]` (or
left/right arrows) cycle in the apply plan's declared order, and `j`/`k` or
arrows scroll the focused pane. Wide terminals keep a 42-cell capability panel
beside the preview and use `Tab` to change focus; medium terminals use a
full-width capability view; narrow terminals stack the selection summary above
the scrollable details. `c` or `esc` returns to the preview without losing
selection or either scroll position.

Capability details are read only from the exact-revision CLI manifest. The
cockpit validates schema version, full revision, system/platform identity, and
the planned host's canonical ID before showing purpose, active state,
resolved deliverables, and ownership/security/mutable-state boundaries.
Loading and inventory failures remain textual and never block confirmation or
fall back to stale data.

Startup and refresh perform no activation. The operator must open the
confirmation step and accept it; the real apply uses that same exact commit, so
the activated configuration cannot drift from the preview if the branch
advances while the cockpit is open. The `ctrl+o` Ask overlay remains read-only
and preserves the full cockpit state.

## Applying a configuration

```sh
atyrode apply            # activate the latest published main; no checkout needed
atyrode apply --plan
atyrode apply --dry-run
atyrode apply --preview-json # stable schema for the read-only dry-run preview
atyrode apply-status     # reconnect to the latest manager-owned apply job
atyrode apply-status JOB --json
```

The default host comes from `ATYRODE_HOST`, then the managed host identity file,
then an unambiguous user/system/hostname match.

Without `--repo`, apply resolves the requested ref (default `main`) to an exact
commit with `git ls-remote`. A published CLI whose revision differs first
builds and invokes that commit's `atyrode`, before host resolution or job
submission. The target revision owns bootstrap, activation and all follow-up
probes; the replaced CLI never interprets the new generation.

No local checkout is involved. Pinning the resolved commit bypasses the flake
tarball cache, so an apply immediately after a merge selects that merge.
`--ref` selects a branch, tag, or full commit instead of `main`:

```sh
atyrode apply --ref feature-branch --plan
```

`--repo PATH` switches to a local checkout for development, for example to
activate work in progress before pushing. It additionally validates the
checkout and Git repository and reports a dirty tree:

```sh
atyrode apply wsl --repo /home/alex/nix-dotfiles --plan
```

Before calling `nh`, the CLI validates the host, user, system, backend, and
revision. `--plan` performs no activation. `--dry-run` uses `nh`'s build-only
path. A successful real activation records the canonical host atomically;
failures and dry runs do not update state.

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

**A plan first.** The steps that will change this machine, numbered, before any
of them run. `--plan` prints exactly that list and stops:

```
Plan
  1. Rebuild and switch macbook through nh-darwin.
  2. Record macbook as the activated host.
  3. Converge the account login shell.
  4. Review the provisioning surfaces this machine declares.
```

**The argv of anything that acts.** Every command that changes the machine,
reaches the network, prompts, or takes real time is printed before it runs,
shell-quoted so the line can be pasted back to repeat that step by hand. The
contract covers every mutating verb, not just `apply`: the `nh` switch, the
`git ls-remote` that resolves a ref, the `systemd-run` that hands the apply to
a manager-owned unit, `chsh` and the `/etc/shells` edit, each provisioning
ceremony and the interactive seed dialogue, every Bitwarden call that logs in,
unlocks, syncs or writes an item, `nix-store --gc` and `nh clean`, every
rollback that re-runs activation, the Clan deployment that activates a remote
host, and the `curl` that enrolls this machine with a fleet master.

Read-only probing stays silent: printing every `command -v` and `bw status`
would bury the handful of commands that act. So does the shell's own
bookkeeping — a `mkdir`, a `chmod`, the `mv` that installs a rendered file
atomically. Where one of those writes something persistent, the path is named
in prose instead, which is what an operator actually needs:
`rendered ~/.ssh/authorized_keys with 4 granted key(s)`.

Two commands are deliberately described rather than quoted. `systemd-run`
carries the machine's whole forwarded `PATH`, so its argv would bury the run it
introduces; the terminal gets the unit name and the log gets the argv. And no
announcement may print a secret: a Bitwarden note body travels on stdin, a
broker credential in a file, a bearer token in a mode-600 `curl` config, so
what reaches the terminal is a verb, an id, and a path.

**Whose password prompt it is.** nix-darwin and NixOS activate as root, and the
backend elevates for that itself. Unannounced, `sudo` interrupts the build from
inside someone else's output and reads as the dotfiles asking for root out of
nowhere, so the step says so first:

```
1/5 Rebuild and switch macbook through nh-darwin
  activation writes system state, so nh elevates: a sudo prompt below is its own
  $ env LC_ALL=en_US.UTF-8 nh darwin switch ...
```

**A verdict per step**, with the declaration or diagnosis that made it
necessary. A step never ends in silence, because a silent step is
indistinguishable from a hung one:

```
3/5 Converge the account login shell
  why fleet/system-boundary.json declares /run/current-system/sw/bin/zsh
  ok already the account login shell

4/5 Review the provisioning surfaces this machine declares
  why fleet/provisioning.json declares 6 surfaces for this machine
  ok 4 ok, 1 not-applicable, 1 incomplete -- still to configure: babel-archive

5/5 Render this machine's agent context
  why every agent tool here reads this file, and the review above may have changed what is authenticated
  $ atyrode context render
wrote /Users/alex/.config/agents/AGENTS.md
  ok
```

A run that aborts still owes a verdict on the steps it promised. Without one,
a failure at step 1 of 5 leaves steps 2 through 5 missing from the terminal,
which reads as though they ran and said nothing:

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

**A durable log.** Every run of a mutating verb — `apply`, `provision`,
`clean`, `rollback` — writes a timestamped, mode-600 transcript of the same
story to `$XDG_STATE_HOME/atyrode/logs/<UTC>-<verb>.log`, named in the closing
summary and again on any failure. The terminal is for the operator watching;
the log is for the diagnosis three weeks later. It is the same contract, and
the same file layout, as the bootstrap's own run log (see
[bootstrap.md](bootstrap.md)), because the two narrate the same machine.

A supervised apply (below) writes two, and the pair is the chain: the
submitting shell's `-apply.log` records the handoff, including the full
`systemd-run` argv that is deliberately kept off the terminal, and the
worker's `-apply-job.log` records the run itself. The summary names the one
that holds the story.

Narration is on stderr and the data is on stdout, so `--json` and
`--preview-json` stay machine-readable while the story still reaches a
terminal beside them.

On Linux with an available systemd user manager, a mutating apply runs in a
transient service rather than as a child of the invoking terminal. Job
metadata, output, and the atomic final result live under
`$XDG_STATE_HOME/atyrode/apply-jobs` (or `~/.local/state/atyrode/apply-jobs`),
and the CLI exits with the activation's own status. What the operator gets
depends on whether there is one:

- Started from a terminal (stdin and stdout both a tty), the job is handed that
  terminal with `systemd-run --pty`. Activation output streams as `nh` produces
  it, and whatever the activation or the reviews below ask for — a `sudo`
  password, the Bitwarden password behind a provisioning offer — is answerable
  in place. The trade is that the job ends with the terminal instead of
  outliving it; its log records where the output went rather than a copy of it,
  so `apply-status` cannot claim a transcript it never captured.
- Without a terminal (CI, a pipe, a timer), the job is detached: the CLI prints
  the durable job ID, waits quietly, replays the captured output at the end,
  and exits. Closing the terminal does not terminate the activation; reconnect
  with `atyrode apply-status [JOB]`.

Read-only plans and dry runs remain terminal-bound. Platforms without a systemd
user manager retain the direct activation path, which is live and interactive by
construction.

After a successful activation, apply reports plain-omp settings that drifted
from the seeded repository defaults (see
[Agent tools](agent-tools.md#seeded-plain-omp-defaults)) and, when running on
a terminal without `--json`, offers a per-key keep-or-reset review. Drift is
never resolved automatically; skipping the review keeps every local value.

apply also reports the provisioning surfaces this machine has left
unconfigured: Babel session-archive health from the placed storage document
and the stamp Babel's push wrapper writes (see
[Agent tools](agent-tools.md#session-archive)), and an incomplete Git
identity — a `user.signingKey` whose public file is missing, or a reachable
agent holding no keys. Without a terminal each one prints the command that
fixes it and nothing else. On a terminal a surface with a ceremony becomes an
offer (`run atyrode provision git now?`), and accepting runs exactly that
command in this terminal — what apply does and what the operator would have
typed are the same thing. Declining prints the reminder unchanged. The archive
has no ceremony to offer: its document is a clan var placed by the activation
itself, so a machine without one is told which generation it is owed
(`clan vars generate HOST` on an operator device, then apply), a configured
machine that has never pushed successfully gets `babel archive status` and
`babel archive push`, and an archive that has not succeeded within 48 hours
is reported stale. None of this can fail the activation: a machine that
declines to provision is still a machine that activated.

An offer resolves the prerequisites it knows about before asking about the
surface, because a question is only fair if the answer can work. Prerequisites
are declared once in `fleet/provisioning.json` as an ordered chain per
surface -- the Git identity needs a Bitwarden session -- and each carries what
is lost without it. On a terminal every unmet link becomes its own offer, in
declared order:

```
Git identity is not configured: ...
  Git identity needs a Bitwarden session, and without it no secret can be read on this machine, so nothing the vault holds can be configured
atyrode: run atyrode vault login now? [y/N] y
  $ atyrode vault login
atyrode: run atyrode provision git for macbook now? [y/N]
```

Telling an operator who is sitting at the prompt to go and type a command this
CLI owns wastes the one moment they are there to answer, and the ceremony would
only fail on it again, one link further in and a password poorer. Each link is
asked for separately because declining one makes every question after it moot,
and because links are shared: every surface that wants the same session
settles it once, and the next stops asking. Off a terminal the chain is stated
instead, since there is nobody to answer.

The session a link opens survives the rest of the run. `atyrode vault login`
runs as its own process, so it hands its session key back through a private
file the parent created and removes; the ceremony that follows inherits it and
never asks for the master password a second time. The key itself is captured
with `bw login --raw` and never displayed: a plain `bw login` ends by printing
the key it minted as copy-paste advice, onto the terminal and into any
transcript the operator shares.

The vault command is `atyrode vault login`, which pins this fleet's EU server
before logging in. A bare `bw login` reaches the US default and fails a first
login with a misleading "invalid master password", so it is never the advice
given.

When an accepted ceremony stops anyway, the reason is the ceremony's own and
the follow-up says so: `clear what it reported above, then: atyrode provision
babel`. Naming the same command as a retry would send an operator to collect
the identical failure.

Linux uses `nh home switch`; macOS uses `nh darwin switch`. Plans name the
selected host and capabilities, installable, source, backend, revision,
dirty-tree state, and mutation boundary. Add `--json` for automation.
Activation shows a generation package diff.

## Deploying another machine

```sh
atyrode fleet plan dev-01           # vars, reachability, evaluation; activates nothing
atyrode fleet apply dev-01          # build here, activate there, verify
atyrode fleet apply dev-01 --json --yes
```

`apply` converges the machine it runs on; `fleet apply` converges another one
over SSH, which is the only difference between them. Clan builds the closure
on this machine and activates it on the target, so the target needs no
toolchain and no checkout. Where it is reached is the machine's own
`clan.core.networking.targetHost`: a deployment cannot be aimed somewhere the
reviewed configuration does not name.

Both verbs refuse a machine clan does not deploy -- a portable profile has no
system closure -- and say which command converges it instead. The
run stops before touching the machine when its vars are not generated (the
remedy names `clan vars generate <host>`) or when it does not answer a
strict-host-key check. After activation the machine is asked who it is, and a
deployment that activated the wrong closure fails there rather than exiting
zero.

Deploying reaches outside this repository for nothing: the machines are this
flake's, the operator identity is the device's own age key rather than a vault
session opened per run, and where a machine is reached is its own declaration
rather than a separate enrollment inventory.

## Agent context

```sh
atyrode context render   # write ~/.config/agents/AGENTS.md and name the path
atyrode context show     # print what render would write
atyrode context --json   # the generated machine section as data
```

Every agent on a machine starts from one file: the operator policy kept in
`modules/home/agents/AGENTS.md`, followed by a generated `## This machine` section.
`context render` writes it to `${XDG_CONFIG_HOME:-~/.config}/agents/AGENTS.md`
(mode 0644, written whole and moved into place), and Home Manager makes
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.omp/agent/AGENTS.md`
out-of-store symlinks to it, so every tool reads the same bytes and no
tool-specific instruction file is maintained by hand. Activation renders it
(`modules/home/agents/default.nix`) and `atyrode apply` renders it again as its last step, after
the provisioning review may have opened sessions, so the file describes the
machine apply leaves behind. This is
[ADR 0008](adr/0008-fleet-shape-and-substrate.md) step 2 and invariant 9 of
the repository's own `AGENTS.md`: context propagation is this repository's
job.

The generated section carries the generation timestamp and the dotfiles
revision the CLI came from; this host's registry identity, platform,
activation owner, and capabilities; the other registered hosts by name and
role; which CLIs are authenticated here and as whom (`gh`, `clever`, and the
Bitwarden vault state), each missing session with the exact command that
acquires it; the secrets readable here by name (none until ADR 0008 step 3,
which the section says in so many words); the fleet cache substituter from the
inventory and whether this machine's Nix daemon trusts it; and the canonical
clone root, which no registry field declares yet, so the section says so
rather than guess. It never contains a secret value: a session is reported by
account name, a secret by its name and path.

`doctor provisioning` carries the matching `agent-context` surface: `ok` when
the file is fresh, `degraded` with remediation `atyrode context render` when
it was rendered from another published revision than the running CLI, is
older than seven days, or carries no generation stamp, and `incomplete` when
it is absent. The file is never edited by hand: if it is wrong, `doctor` is
wrong.

## Machine key

The machine key is the age key clan vars are decrypted with at activation,
this machine's own and never the operator's. It is clan's: `clan vars
generate <host>` mints it on an operator device, keeps the private half in
the repository under `sops/secrets/<host>-age.key` encrypted to the `admins`
group, and records the public half under `sops/machines/<host>/key.json`.
`apply` places it at `/var/lib/sops-nix/key.txt` -- the path
[`modules/shared/clan-machine.nix`](../modules/shared/clan-machine.nix) hands
sops-nix on both classes -- as its first step on a clan machine, before the
switch, so the activation that follows decrypts the machine's vars. Both
commands the step runs are announced: `clan secrets get <host>-age.key` into
a mode-600 file in a mode-700 scratch directory, then
`sudo install -D -m 0600 -o root` from there to the key's path, the scratch
directory going with the step whatever its outcome. The key never reaches
argv, a terminal, or the run log. On a device with no registered operator
key the step says which device can place it instead.

```sh
atyrode provision machine-key   # clan vars generate <host>, from the machine itself when it is an operator device
```

`apply` offers that on a clan machine whose key is not in the repository, and
`doctor provisioning` carries the `machine-key` surface: `not-applicable` on
a portable profile, `incomplete` while the
repository holds no key, `degraded` when it does but the machine has not been
applied since, and `ok` when placed. The model, enrolment, and revocation are
in [secrets.md](secrets.md).

## Operator identity

```sh
atyrode operator show     # this device's public age recipient, and whether clan registers it
atyrode operator init     # mint the key if absent; print the two clan commands that register it
```

The operator identity is the age key that edits secrets: one per device the
operator works from, registered as clan user `alex-<host>` in the `admins`
group every value is encrypted to. On a Mac it is minted by `age-plugin-se`
inside the Secure Enclave, unlocked by Touch ID (or the login passcode) on
every use, and by construction impossible to copy off the machine; anywhere
else it is a plain age key written by `age-keygen`. Both verbs apply on every
fixed host and refuse on a portable profile with exit 65 and one sentence;
the platform branch reads the host registry's system, not `uname`, so the
check drives the Mac's ceremony from a Linux sandbox. `init` writes
`~/.config/sops/age/keys.txt` (mode 0600 under a mode-0700 directory),
announces the one generator command it runs, and prints the two commands
that register the result (`clan secrets users add alex-<host> age1...` and
`clan secrets groups add-user admins alex-<host>`). It never replaces an
existing `keys.txt`: a key there is kept and its registration repeated, and
a file without a `# public key:` line is refused with the way out said. Only
that comment line is ever read; the identity line never reaches the
terminal, argv, or the run log.

`apply` offers `operator init` on a device that has no key, and `doctor
provisioning` carries the `operator-identity` surface right after
`machine-key`: `not-applicable` on a portable profile, `incomplete` with no
usable key, `degraded` with the exact registration commands when the key
exists but clan does not register it in the group, and `ok` when registered.
The per-device model and what a lost device costs are in
[secrets.md](secrets.md).

## Inspection and diagnostics

```sh
atyrode capabilities list --json
atyrode capabilities show wsl --json
atyrode runtime status local-qwen --json
atyrode runtime provision local-qwen
atyrode runtime run local-qwen
atyrode runtime shortcut local-qwen
atyrode runtime provision manifold-agent
atyrode runtime status manifold-agent --json
atyrode provision git
atyrode auth broker status --json
atyrode auth broker add-api-key PROVIDER
atyrode inventory --json
atyrode inventory --host wsl --json
atyrode inventory --ref <branch-tag-or-commit> --json
atyrode inventory --repo /absolute/path/to/checkout --json
atyrode lifecycle
atyrode lifecycle --json
atyrode doctor host --json
atyrode doctor system --json
atyrode doctor git --json
atyrode doctor tools --json
```

`provision git` reconciles this machine's Git SSH auth/signing keys against
the Bitwarden vault (one-time, interactive); custody details live in
[git-keys](git-keys.md).

Managed `local-qwen` OMP processes hold independent session leases. Ten minutes
after the final session closes, the WSL idle reaper verifies that vLLM has no
active or queued requests and no new token activity, then stops the container
and releases its GPU memory. A new session or direct API activity resets the
deadline; stale leases from crashed processes are discarded.

`manifold-agent` joins the machine to the self-hosted manifold hub declared in
`fleet/manifold.json`; enrollment, upgrade discipline, replacing an unmanaged
agent, and the master-migration runbook live in [manifold](manifold.md).

`inventory` is a thin, read-only consumer of the flake's schema-versioned
evaluated manifest. By default it evaluates the exact immutable revision baked
into the installed CLI, so an older binary cannot accidentally describe its own
packages while targeting a newer revision. `--ref` selects a published target
revision and `--repo` selects a local checkout; they are mutually exclusive.
`--host` resolves a canonical host name inside that evaluated revision.
The command currently requires `--json`, returns compact key-sorted JSON, and
does not inspect closures, credentials, sessions, or other mutable state.

`lifecycle` is a local, read-only report rather than a cleanup command. It
inspects only the Home Manager profile, native worktrees of the configured
dotfiles checkout, OMP's default `~/.omp` state root (including session
count/size), OMP's documented `~/.omp/wt` worktree root, and the named
OMP/atyrode cache and state paths; it never recursively searches HOME. JSON rows
carry a category, path, observed byte size (or `null`), evidence, owner, state,
and conservative classification. The additive top-level `omp` object contains
`stateRoot`, `sessions`, `worktreeRoot`, per-worktree reports, `caches`, and
`dryRuns`. OMP worktrees with a dirty Git tree, checked-out branch, or
lock/activity marker are `live` and `protected`; a worktree is `reclaimable`
only when all of those liveness probes are quiet. Unreadable Git state remains
protected as `unknown`.

Decision record: [ADR-0007](adr/0007-explicit-generation-cleanup.md).

When `omp` is available, the same `atyrode lifecycle` report captures the
supported `omp gc` default dry-run and `omp worktree clear --dry-run` output.
When it is absent, the command still exits successfully with the filesystem
report and marks both dry-run probes `unavailable`. It never passes `--apply`,
runs worktree clearing without `--dry-run`, deletes, prunes, installs timers, or
modifies state. Applying OMP GC remains a deliberate manual operator action:
review the report, then run `omp gc --apply` directly.

Diagnostics use stable non-zero exits for invalid input, missing files or tools,
identity mismatches, and activation failure. They do not expose credentials.
`doctor system [HOST] [--json]` audits the boundary that package installation
alone cannot satisfy: the real login shell, Nix daemon and trust policy,
container engine, antivirus ownership, Android device policy, Homebrew drift,
and, on macOS, the residue of an interrupted or superseded Nix installation.
That last one is the state
[`bootstrap/install.sh`](../bootstrap/install.sh) repairs before Nix exists --
a shell rc backup that was never restored, an `/etc` profile file the
installer wrote where nix-darwin expects to own a link, an `/etc` link into a
store path that is gone, a TLS anchor Nix cannot read, an `fstab` line
mounting `/nix` from a volume that no longer resolves. Repair has to run
before Nix exists and stays in the installer; detection is shared knowledge,
so a machine that installed successfully years ago is re-examined on every
`atyrode doctor` and told which command repairs what it carries. Its stable
check IDs, row schema, statuses, exits, and read-only probe contract are
documented in [Home Manager and system boundary](system-boundary.md).
`doctor git [--json]` is the matching user-side, read-only audit. Its ordered
checks cover Git configuration readability, SSH-agent availability and loaded
keys, the configured signing public key and permissions, exact managed
`allowed_signers` content, the current repository's effective fetch/push
protocols, plaintext Git helpers/files, the declarative `gh` helper, and `gh`
token-storage classification. `failed` checks return 69; `warning` rows (for
example, an HTTPS forge push with no recognized secure helper) remain visible
without making the report fail. JSON uses schema version 1 and never includes
keys, tokens, helper arguments, or remote URLs. Bootstrap, headless policy,
rotation, revocation, recovery, and platform verification are documented in
[Git SSH authentication and signing](git-keys.md).
The `workspace` and `agent` namespaces are reserved for their owning follow-up
issues and currently fail clearly.
