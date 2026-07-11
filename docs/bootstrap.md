# Bootstrap and migrations

The bootstrap is the only supported path from an unmanaged machine to a
registered dotfiles host. It is conservative because it runs before the
managed environment is known to work.

## Fresh-machine command

Choose the host from [`hosts/default.nix`](../hosts/default.nix), then run this
single command. This example selects the ordinary x86_64 Linux profile:

```sh
git clone https://github.com/atyrode/dotfiles.git "$HOME/nix-dotfiles" && "$HOME/nix-dotfiles/install.sh" apply --config alex-x86_64-linux
```

Substitute the exact registered host for a Mac or desktop Linux machine.
Bootstrap never infers a profile from architecture alone: x86_64 Linux can be
the base development machine or the desktop profile. Production NixOS servers
instead import the [portable Home Manager profile](portable-profiles.md) from
their infrastructure flake.

The unmanaged prerequisites are Git, Bash, `curl`, `tar`, and either
`sha256sum` or `shasum`. The command clones inspectable code before executing
it; there is no supported `curl | shell` path.

## Phases and source policy

The phases are independently callable:

```sh
./install.sh preflight --config alex-x86_64-linux
./install.sh plan --config alex-x86_64-linux
./install.sh apply --config alex-x86_64-linux
./install.sh verify --config alex-x86_64-linux
./install.sh rollback --yes
```

`preflight` verifies the platform, explicit host selection, repository root,
raw and Git-resolved origin, branch/revision relationship to cached
`origin/main`, required tools, and the absence of an interrupted transaction.
It rejects staged, tracked, and untracked changes. `plan` adds the ordered Nix,
migration, activation, and verification actions without creating state,
downloading an artifact, fetching Git, or moving a file.

`apply` repeats both phases and asks for confirmation. Once Nix is available it
uses the packaged `atyrode apply` plan and activation, so the host registry and
the `nh` backend remain the only activation contract. Flakes are enabled only
through the process-scoped `NIX_CONFIG`; bootstrap does not append to a
user-owned `nix.conf`. After the Home Manager transaction succeeds, bootstrap
also verifies the system-owned login-shell prerequisite described in [Home
Manager and system boundary](system-boundary.md).

Use `--update` to explicitly fetch the verified origin and fast-forward main.
If source changes, bootstrap re-enters the fetched `install.sh` before opening
a transaction. It never pulls implicitly. `--allow-dirty` and
`--allow-non-main` are review acknowledgements for intentional local work;
`--update` cannot be combined with a dirty checkout. A Git `url.*.insteadOf`
rewrite cannot redirect the accepted GitHub origin unnoticed.

## Nix installer decision

Fresh machines install upstream Nix 2.34.7 from the official
`releases.nixos.org` archive. The four archive SHA-256 values are embedded in
`install.sh` for x86_64/aarch64 Linux and Darwin. Bootstrap downloads into a
private temporary directory, verifies the complete archive before extraction,
checks the expected installer path, and only then runs the upstream multi-user
installer. Existing Nix installations are reused.

This choice was reviewed on 2026-07-10:

- [Upstream Nix](https://nix.dev/manual/nix/latest/) keeps the existing runtime,
  supports all four repository targets (including the Intel Mac while it
  remains registered), and provides official versioned release archives. Its
  multi-user uninstall is manual and OS-specific rather than receipt-driven.
- The [Lix installer](https://git.lix.systems/lix-project/lix-installer) has
  strong plan, receipt, recovery, and uninstall behavior without diagnostic
  telemetry, but selecting it also changes the Nix implementation and its
  current Intel-Mac path is legacy. That product/retirement decision is outside
  bootstrap hardening.
- The [Determinate installer](https://github.com/DeterminateSystems/nix-installer)
  has strong planning and receipt-based uninstall, but now defaults to
  Determinate Nix, its upstream-Nix compatibility flag was documented only
  through 2026-01-01, current releases do not cover Intel Darwin, and
  diagnostics are enabled unless configured otherwise.

The bootstrap transaction records the selected upstream version, platform
hash, source disposition, and repository revision. A partial upstream
installer failure remains visible as a failed bootstrap receipt. Bootstrap
does not automatically remove a system-wide Nix install: that could destroy a
pre-existing or concurrently repaired store. To uninstall a bootstrap-created
Nix, first preserve the failed receipt, confirm that Nix was not present before
the run, and follow the official
[multi-user uninstall procedure](https://nix.dev/manual/nix/2.22/installation/uninstall)
for the current OS. That procedure is destructive and intentionally remains an
operator action.

## Transactions, receipts, and recovery

Bootstrap state lives under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/
├── apply.pending/
├── login-shell.incomplete
├── migrations/
│   └── migration-v1-shell-entrypoints.{pending,complete,rolled-back}
└── transactions/
    └── apply-v1-<timestamp>-<process>.{complete,failed,rolled-back}
```

`apply.pending` is constructed privately and published by one rename only
after its receipt, prior host-state snapshot, and checksummed recovery copies
are complete. An interrupted pre-publication directory is preserved as an
`*.abandoned` transaction on the next apply; it is never interpreted as a
successful or recoverable apply. Completed receipts contain schema/version
identifiers, hashes, relative logical actions, phases, host, system, revision,
and outcome. They do not contain repository/home absolute paths, remote URLs,
environment dumps, or credentials.

The versioned shell-entrypoint migration applies only to unmanaged `.zshrc`
and `.zshenv` files or symlinks. It writes a relative-path manifest before the
first move, resumes safely after interruption, and commits only after Home
Manager links both applicable paths. It never executes an unmanaged file to
infer ownership. Actual backups may naturally contain private shell content;
their parent directories are mode `0700` and must be protected like any other
local backup.

An activation or verification failure invokes the transaction-owned recovery
copy, verifies its SHA-256, restores every migration-owned entrypoint only when
there is no user-created collision, restores the previous active-host state,
and archives the journal as failed. If the process is killed after the pending
marker is published, run:

```sh
./install.sh rollback --yes
```

Rollback refuses ambiguous dual receipts, corrupted manifests, missing or
changed backups, symlinked state namespaces, and newly-created destination
data. On refusal, preserve both the pending transaction and live paths; do not
delete either copy. If the checkout is unavailable, run the transaction-owned
copy directly:

```sh
bash "${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/apply.pending/recovery/install.sh" rollback --yes
```

This rollback restores bootstrap-owned filesystem moves and the active-host
receipt. It does not uninstall Nix or roll back a successfully activated Nix or
nix-darwin generation. Those are separate, explicit system operations.

The login shell is deliberately outside the Home Manager transaction. On
standalone Linux, bootstrap verifies the managed Zsh executable, registers it
once in `/etc/shells` with explicit privilege, selects it with `chsh`, and
reads the account database back. On macOS, nix-darwin owns the equivalent
`UserShell` activation and bootstrap verifies its result. `$SHELL` is never
accepted as proof because an inherited environment can be stale or forged.

If this post-activation prerequisite cannot be completed, bootstrap returns
`69` but leaves the successful Home Manager activation and completed receipt
intact. It atomically publishes `login-shell.incomplete` before archiving the
completed receipt, and clears it only after account-database verification, so
an interruption cannot look like a fully ready machine. Fix the system
prerequisite and run `./install.sh verify --config <host>`, or rerun `apply`
with the required privilege. A passing verification removes the marker.

## Verification coverage

`checks/bootstrap.nix` uses temporary homes and repositories. It covers a clean
plan, fresh and repeated application, successful and failed source updates,
wrong and rewritten origins, dirty/staged/non-main revisions, download and
checksum failure, partial installer failure, activation and verification
failure, interruption before and after transaction publication, resumable
migration, collisions, corrupt and dual receipts, missing backups, symlinked
state namespaces, rollback, receipt privacy, login-shell marker interruption,
unsafe marker types, privilege failure and recovery, production-only test-hook
gating, and idempotence. The same check runs natively in all four CI jobs.
