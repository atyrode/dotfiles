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

Without `--repo`, apply activates the published flake. It resolves the
requested ref (default `main`) to an exact commit with `git ls-remote`, then
activates the pinned `github:atyrode/dotfiles/<commit>`. No local checkout is
involved, so the command behaves identically from any directory on any
machine, and pinning the resolved commit bypasses the flake tarball cache: an
apply immediately after a merge activates that merge. `--ref` selects a
branch, tag, or full commit instead of `main`:

```sh
atyrode apply --ref feature-branch --plan
```

`--repo PATH` switches to a local checkout for development, for example to
activate work in progress before pushing. It additionally validates the
checkout and Git repository and reports a dirty tree:

```sh
atyrode apply alex-x86_64-linux-desktop --repo /home/alex/nix-dotfiles --plan
```

Before calling `nh`, the CLI validates the host, user, system, backend, and
revision. `--plan` performs no activation. `--dry-run` uses `nh`'s build-only
path. A successful real activation records the canonical host atomically;
failures and dry runs do not update state.

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
unconfigured: Babel session-archive health from the stamp Babel's push wrapper
writes (see [Agent tools](agent-tools.md#session-archive)), and an incomplete
Git identity — a `user.signingKey` whose public file is missing, or a reachable
agent holding no keys. Without a terminal each one prints the command that
fixes it and nothing else. On a terminal each becomes an offer (`run atyrode
provision babel for HOST now?`, `run atyrode provision git now?`), and
accepting runs exactly that command in this terminal — what apply does and what
the operator would have typed are the same thing, including the timer the
ceremony arms. Declining prints the reminder unchanged. A configured machine
that has never pushed successfully gets `babel archive status` and `babel
archive push`, and an archive that has not succeeded within 48 hours is
reported stale. None of this can fail the activation: a machine that declines
to provision is still a machine that activated.

Linux uses `nh home switch`; macOS uses `nh darwin switch`. Plans name the
selected host and capabilities, installable, source, backend, revision,
dirty-tree state, and mutation boundary. Add `--json` for automation.
Activation shows a generation package diff.

## Fleet SSH access

```sh
atyrode tunnel list
atyrode tunnel list --json
atyrode tunnel grant alex-macbook-air --for 8h
atyrode tunnel grant alex-macbook-air --for until-revoked
atyrode tunnel revoke alex-macbook-air
```

`tunnel` answers one question: which reviewed fleet keys may reach **this**
machine over SSH. It has two inputs and one output. The input that is fleet
policy is [`home/ssh-fleet-keys`](../home/ssh-fleet-keys) — public keys only,
changed exclusively through a reviewed commit, exactly as a signing key becomes
trusted only through a reviewed commit in `home/git-allowed-signers` (see
[git-keys](git-keys.md)). The input that is local decision is a grant file under
`$XDG_STATE_HOME/atyrode/tunnel/grants.json`. The output is
`~/.ssh/authorized_keys`, which atyrode owns: every mutation re-renders the whole
file from registry plus grants, atomically, at `0600`, keeping the
pre-management file once at `~/.ssh/authorized_keys.pre-atyrode`.

Registration is not access. A key in the registry is grantable, nothing more.
`grant` defaults to a timed grant and `--for` accepts `1h`, `8h`, `24h`, `7d`,
or the explicitly unbounded `until-revoked`; the cockpit's Tunnel workspace
offers exactly that set. A timed grant renders OpenSSH's own
`expiry-time="YYYYMMDDHHMM"` option, so **sshd** refuses the key once the
deadline passes — no timer, no daemon, and no requirement that this machine or
atyrode still be running for access to lapse. Because the option carries no `Z`,
sshd reads it in the system time zone, which is the zone atyrode formats it in.
Pruning a lapsed row from the grant file is hygiene; the expiry is the
mechanism.

The first mutation on a machine adopts the keys already in `authorized_keys` as
unbounded grants, because that is what those lines already meant; without that,
the first grant would silently revoke every other machine, including the key
carrying the session doing the granting. A key present in `authorized_keys` but
absent from the registry blocks the render and is named, rather than being
dropped: registering it or removing it is the operator's call.

Exactly one registry entry is `primary`. It is rendered on every machine with no
expiry, `revoke` refuses it before the vault is consulted, and the cockpit
refuses it without running anything. That is the lockout protection for a host
reachable only over SSH; moving the role is a reviewed registry change.

### The vault gate is intentionality, not privilege

`grant` and `revoke` open a Bitwarden session first, reusing the unlock
ceremony of [`scripts/babel-storage-configure.sh`](../scripts/babel-storage-configure.sh)
and `atyrode provision git`: unlock if locked, relock on every exit path if this
command opened the session. `list` is read-only and never touches the vault.

That gate exists so a grant is a deliberate operator act — in particular, an
agent running as this user cannot toggle fleet access unattended. It is
explicitly **not** a root-compromise boundary and must not be read as one.
Anything already running as this user can write `~/.ssh/authorized_keys`
directly, and an already-unlocked vault satisfies the gate with no prompt until
`atyrode vault lock`. The boundary it does provide is that a mutation cannot
happen without either an operator at the terminal or a vault the operator chose
to leave unlocked.

### Grant state is not part of a Nix generation

The registry is in the flake, but the grant file and the rendered
`authorized_keys` are machine-local mutable state. Applying this configuration
neither creates nor changes them, and a Nix generation rollback does not restore
them — the same non-transactional boundary the native Windows package phase
carries. To undo access, revoke it; to recover the pre-management file, the
one-time backup is still there.


## Inspection and diagnostics

```sh
atyrode capabilities list --json
atyrode capabilities show alex-x86_64-linux --json
atyrode runtime status local-qwen --json
atyrode runtime provision local-qwen
atyrode runtime run local-qwen
atyrode runtime shortcut local-qwen
atyrode runtime provision manifold-agent
atyrode runtime status manifold-agent --json
atyrode provision git
atyrode auth broker status --json
atyrode inventory --json
atyrode inventory --host alex-x86_64-linux --json
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
`inventory/manifold.json`; enrollment, upgrade discipline, the tyrode-dev-01
cutover, and the master-migration runbook live in [manifold](manifold.md).

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
container engine, antivirus ownership, Android device policy, and Homebrew
drift. Its stable check IDs, row schema, statuses, exits, and read-only probe
contract are documented in [Home Manager and system boundary](system-boundary.md).
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
