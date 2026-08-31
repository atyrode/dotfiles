# Bootstrap

The bootstrap is the only supported path from an unmanaged machine to a
registered dotfiles host. It is conservative because it runs before the
managed environment is known to work.

## Fresh-machine command

Run one command and choose from the registered presets compatible with the
machine:

```sh
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash
```

`get.sh` lists each preset with its description and capability breakdown from
`inventory/hosts.tsv`, then prompts for an explicit choice on the terminal.
For non-interactive Linux automation, pass the architecture-specific portable
profile and confirm the printed plan explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash -s -- development-x86_64-linux --yes
```

Portable profiles validate and bind the invoking non-root user and canonical
home directory at activation time. They reject a foreign-owned home or a home
that disagrees with the account database. Fixed machine profiles retain their
declared repository identity. Bootstrap validates explicit target names and
never infers between portable, fixed, desktop, or Mac configurations.
Production NixOS servers instead import the
[portable Home Manager profile](portable-profiles.md) from their infrastructure
flake.

`get.sh` is deliberately thin: it verifies Git is present, clones the
repository to `~/nix-dotfiles` (`DOTFILES_DIR` overrides it; an existing
directory is reused only when its origin is this repository), and hands off to
the cloned `install.sh`, which owns every mutation.

A reused directory is never trusted at whatever revision it holds. Its
`install.sh`, host inventory, and `main` can all be stale, and a stale
`install.sh` would otherwise decide what the freshly fetched entry point
means. The fetched command means "install current upstream main", so reuse is
routed through `install.sh --update`, which fast-forwards the verified origin
and re-enters the updated script. `get.sh` reports the directory it adopted so
a refusal about a branch or a dirty tree names a checkout the operator can
find. Passing `--update`, `--allow-dirty`, or `--allow-non-main` is a reviewed
decision about which revision to activate, and suppresses the implicit update.
A fresh clone already sits at `origin/main` and is handed off unchanged.

The 2026-07-10 decision to
support no `curl | shell` path was revised on 2026-07-11 with these
mitigations: the fetched script is function-wrapped so a truncated download
executes nothing, the confirmation prompt reads from the terminal and a
non-interactive run requires an explicit `--yes`, and the bootstrap below
still executes only from cloned, inspectable code. The
clone-first command remains supported and equivalent:

```sh
git clone https://github.com/atyrode/dotfiles.git "$HOME/nix-dotfiles" && "$HOME/nix-dotfiles/install.sh" apply --config development-x86_64-linux
```

The unmanaged prerequisites are Git and Bash. `curl` is needed only when `nix`
is absent, and `tar` plus `sha256sum` or `shasum` only for a fresh Nix
install.

## Phases and source policy

The phases are independently callable:

```sh
./install.sh preflight --config development-x86_64-linux
./install.sh plan --config development-x86_64-linux
./install.sh apply --config development-x86_64-linux
./install.sh verify --config development-x86_64-linux
```

`preflight` verifies the platform, explicit host selection, repository root,
raw and Git-resolved origin, branch/revision relationship to cached
`origin/main`, and required tools, and warns when a previous apply was
interrupted.
It rejects staged, tracked, and untracked changes. `plan` adds the ordered
repair, Nix, activation, and verification actions without creating state,
downloading an artifact, fetching Git, or moving a file.

`apply` repeats both phases and asks for confirmation. Once Nix is available it
uses the packaged `atyrode apply` plan and activation, so the host registry and
the `nh` backend remain the only activation contract. Flakes are enabled only
through the process-scoped `NIX_CONFIG`; bootstrap does not append to a
user-owned `nix.conf`. After the Home Manager activation succeeds, bootstrap
also verifies the system-owned login-shell prerequisite described in [Home
Manager and system boundary](system-boundary.md).

Use `--update` to explicitly fetch the verified origin and fast-forward main.
If source changes, bootstrap re-enters the fetched `install.sh` before writing
the interrupted-apply marker. It never pulls implicitly. Because `--update`
already requires a clean tree, a checkout parked on another branch is returned
to main as part of the update rather than refused: moving `HEAD` leaves that
branch and every commit on it intact, and bootstrap prints the `git checkout`
that goes back. A local main holding commits absent from `origin/main` still
stops the update. `--allow-dirty` and `--allow-non-main` are review
acknowledgements for intentional local work; `--update` cannot be combined
with a dirty checkout. A Git `url.*.insteadOf` rewrite cannot redirect the
accepted GitHub origin unnoticed.

## Nix installer decision

Fresh machines install upstream Nix 2.34.7 from the official
`releases.nixos.org` archive. The three archive SHA-256 values are embedded in
`install.sh` for x86_64/aarch64 Linux and aarch64 Darwin. Bootstrap downloads
into a private temporary directory, verifies the complete archive before
extraction, checks the expected installer path, and only then runs the upstream
installer non-interactively. Linux uses the upstream single-user mode, avoiding
a daemon dependency on containers and other systemd-less environments; macOS
uses its required multi-user mode. The installer does not add channels or edit
shell profiles because the flake and Home Manager own those concerns. Existing
Nix installations are reused. A Linux single-user install may still invoke
`sudo` once to create `/nix` when it does not already exist.

This choice was reviewed on 2026-07-10:

- [Upstream Nix](https://nix.dev/manual/nix/latest/) keeps the existing
  runtime, supports all three repository targets, and provides official
  versioned release archives.
- The [Lix installer](https://git.lix.systems/lix-project/lix-installer) and
  the [Determinate installer](https://github.com/DeterminateSystems/nix-installer)
  were rejected: each changes the Nix implementation or its defaults, which is
  outside bootstrap hardening.

A partial upstream installer failure remains visible through the
interrupted-apply marker. Bootstrap never removes a system-wide Nix install
and never deletes a store: that could destroy state it cannot reconstruct. To
uninstall a bootstrap-created Nix, confirm that Nix was not present before the
run and follow the official
[multi-user uninstall procedure](https://nix.dev/manual/nix/2.22/installation/uninstall)
for the current OS. That procedure is destructive and intentionally remains an
operator action.

The upstream installer also copies every shell rc file it touches to
`<target>.backup-before-nix` and refuses to start when such a backup already
exists and no longer matches its target. An interrupted install therefore
leaves a machine on which every retry fails — late, after the download and the
macOS volume repair — and the upstream remediation reads like an invitation to
delete the backup, which destroys the only copy of the original file.

Repairing that is bootstrap's job, not the operator's. `preflight` evaluates
the same condition upstream does, read-only and only when Nix is actually
missing; `plan` lists every file it will restore; and `apply` performs the
restore with explicit privilege, after confirmation, immediately before the
installer runs. Where the target still exists it is the interrupted install's
own rewritten file, but proving that byte for byte across installer versions
is not worth guessing wrong about on someone's `/etc`, so it is kept as
`<target>.nix-install-leftover` beside the restored original rather than
discarded. A backup identical to its target is left alone, matching upstream,
because a completed install legitimately leaves one behind.

## Self-healing repairs

Bootstrap is the only supported deployment path, so a state it can recognise
is a state it repairs rather than one it reports. Every repair obeys two
constraints:

- **Idempotent.** Detection is read-only and re-derived each run, so a repeated
  run converges instead of compounding. A repair whose work is already done is
  not planned.
- **Reversible.** No repair may destroy state it cannot reconstruct. Where
  content would be lost it is archived first, and every repair appends the
  exact command that undoes it to
  `${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/repairs/undo.log`.

Detection runs in `preflight`, only when Nix is actually missing. `plan` lists
each repair, and `apply` performs it with explicit privilege after
confirmation, immediately before the upstream installer runs.

| State | Repair |
| --- | --- |
| A pre-Nix shell rc backup blocks the installer | Restore it; keep any rewritten target as `<target>.nix-install-leftover` |
| `/etc` links resolve into a store that no longer exists | Remove them; links not owned by this toolchain are left alone |
| `/etc/fstab` names a `/nix` volume UUID that no longer resolves | Drop the line; archive the file first |
| An orphaned `Nix Store` volume exists | Rename it so the installer creates a fresh one |

The volume repair renames rather than deletes. The installer finds volumes by
label, so a rename is enough to route it onto its well-tested fresh-create
path instead of the in-place encryption path that fails on a pre-existing
volume — and unlike deletion, it destroys nothing and undoes with one command.
The orphaned volume keeps its data until the operator reclaims the space.

A volume carrying a live store is in use, not orphaned: a populated store
database suppresses the repair entirely.

## Failure codes

Every operator-facing failure carries a stable code, the reason, and the next
action. Unrecognised states are reported as such, with the transcript path,
rather than surfacing as a bare exit status — a code that does not exist yet
is the request for the repair that should.

| Code | State |
| --- | --- |
| `BOOT-E201` | Installer could not create a shell rc file; `/etc` holds a link into a missing store |
| `BOOT-E202` | Installer refused to start; a pre-Nix shell rc backup is in the way |
| `BOOT-E203` | Installer crashed encrypting a pre-existing Nix volume in place |
| `BOOT-E204` | Installer created the Nix volume but could not mount it |
| `BOOT-E210` | A dangling `/etc` link could not be removed |
| `BOOT-E211` | `/etc/fstab` could not be archived or rewritten |
| `BOOT-E212` | A `Nix Store` volume was found but its device identifier could not be read |
| `BOOT-E213` | The orphaned volume could not be renamed |
| `BOOT-E299` | The upstream installer failed in a way bootstrap does not recognise yet |

`BOOT-E201` through `BOOT-E204` are classified from the upstream installer's
own output. Each names the repair that already handles it, so the remedy is to
re-run bootstrap.

## Run logs

`apply` writes a timestamped transcript per run, and the upstream installer's
own output beside it:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/logs/
├── 20260831T161500Z-apply.log
└── 20260831T161500Z-apply-nix-installer.log
```

Failures print the log path. Logging never fails a run: a machine too broken
to write state is still allowed to attempt its own repair.

## Interrupted-apply marker and recovery

Bootstrap state lives under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/
├── dotfiles-config
├── install-interrupted
└── bootstrap/
    ├── login-shell.incomplete
    ├── logs/
    │   └── <timestamp>-<phase>.log
    └── repairs/
        ├── fstab.<timestamp>
        └── undo.log
```

`apply` writes `install-interrupted` immediately before its first mutating
step. The marker holds two lines, `config=<host>` and `started=<ISO-8601
UTC>`, and is removed only after verification succeeds. While it exists,
`plan` and `apply` print a warning naming the configuration and start time;
`plan` only warns, and a successful `apply` clears it. State is safe after an
interruption — recover by re-running:

```sh
./install.sh apply --config <host>
```

Bootstrap never rolls back a successfully activated generation. Use the
standard `home-manager generations` (or nix-darwin) rollback when a previous
generation is needed.

The login shell is deliberately outside the Home Manager activation. On
standalone Linux, bootstrap verifies the managed Zsh executable, registers it
once in `/etc/shells` with explicit privilege, selects it with `chsh`, and
reads the account database back. On macOS, nix-darwin owns the equivalent
`UserShell` activation and bootstrap verifies its result. `$SHELL` is never
accepted as proof because an inherited environment can be stale or forged.

If this post-activation prerequisite cannot be completed, bootstrap returns
`69` but leaves the successful Home Manager activation intact. It atomically
publishes `login-shell.incomplete` before clearing the interrupted-apply
marker, and clears it only after account-database verification, so
an interruption cannot look like a fully ready machine. Fix the system
prerequisite and run `./install.sh verify --config <host>`, or rerun `apply`
with the required privilege. A passing verification removes the marker.

## Verification coverage

`checks/bootstrap.nix` uses temporary homes and repositories, covering the
read-only plan, fresh and repeated application, source updates, origin and
revision defenses, installer failures and their classification into codes,
every self-healing repair and its undo journal, the interrupted-apply marker
contract, login-shell recovery, unsafe state types, production-only test-hook
gating, and idempotence. The macOS repairs are covered on every platform: the
states they fix cannot be built on a Linux runner, so the check forces the
platform through a test-hook override and stages the volume table behind a
`diskutil` stand-in. The same check runs natively in all three CI jobs.

`checks/get-sh.nix` covers the fetched entry point: the usage and missing-Git
failures, refusal to reuse a foreign target directory, the streamed
piped-stdin handoff to the cloned `install.sh` with `--yes` and recorded
arguments, the implicit `--update` on a reused checkout and its suppression by
each explicit source acknowledgement, the refusal to proceed without a
terminal or `--yes`, and the `DOTFILES_DIR` override with forwarded install
arguments.
