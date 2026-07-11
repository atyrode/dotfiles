# Bootstrap and migrations

The bootstrap is the only supported path from an unmanaged machine to a
registered dotfiles host. It is conservative because it runs before the
managed environment is known to work.

## Fresh-machine command

Choose the host from [`hosts/default.nix`](../hosts/default.nix), then run one
command. This example selects the ordinary x86_64 Linux profile:

```sh
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash -s -- alex-x86_64-linux
```

Substitute the exact registered host for a Mac or desktop Linux machine, or
omit the host entirely: `get.sh` then lists the registered presets for this
machine's system — each with its description and capability breakdown from
`inventory/hosts.tsv` — and prompts for an explicit choice on the terminal
(without one, it refuses and names the valid IDs). Bootstrap never infers a
profile from architecture alone: x86_64 Linux can be the base development
machine or the desktop profile. Production NixOS servers
instead import the [portable Home Manager profile](portable-profiles.md) from
their infrastructure flake.

`get.sh` is deliberately thin: it verifies Git is present, clones the
repository to `~/nix-dotfiles` (`DOTFILES_DIR` overrides it; an existing
directory is reused only when its origin is this repository), and hands off to
the cloned `install.sh`, which owns every mutation. The 2026-07-10 decision to
support no `curl | shell` path was revised on 2026-07-11 with these
mitigations: the fetched script is function-wrapped so a truncated download
executes nothing, the confirmation prompt reads from the terminal and a
non-interactive run requires an explicit `--yes`, and the transactional
bootstrap below still executes only from cloned, inspectable code. The
clone-first command remains supported and equivalent:

```sh
git clone https://github.com/atyrode/dotfiles.git "$HOME/nix-dotfiles" && "$HOME/nix-dotfiles/install.sh" apply --config alex-x86_64-linux
```

The unmanaged prerequisites are Git, Bash, `curl`, `tar`, and either
`sha256sum` or `shasum`.

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
user-owned `nix.conf`.

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

## Verification coverage

`checks/bootstrap.nix` uses temporary homes and repositories. It covers a clean
plan, fresh and repeated application, successful and failed source updates,
wrong and rewritten origins, dirty/staged/non-main revisions, download and
checksum failure, partial installer failure, activation and verification
failure, interruption before and after transaction publication, resumable
migration, collisions, corrupt and dual receipts, missing backups, symlinked
state namespaces, rollback, receipt privacy, and idempotence. The same check
runs natively in all four CI jobs.

`checks/get-sh.nix` covers the fetched entry point: the usage and missing-Git
failures, refusal to reuse a foreign target directory, the streamed
piped-stdin handoff to the cloned `install.sh` with `--yes` and recorded
arguments, the refusal to proceed without a terminal or `--yes`, and the
`DOTFILES_DIR` override with forwarded install arguments.
