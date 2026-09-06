# Bootstrap

The bootstrap is the only supported path from an unmanaged machine to a
registered dotfiles host. It is conservative because it runs before the
managed environment is known to work. `./bootstrap/install.sh --help` lists
its phases and options; this page records the contracts behind them -- what
bootstrap owns and what it hands over, how a repair may behave, what a failure
code means, and how an interrupted run is recovered.

## Bootstrap once, apply forever

Bootstrap's job is to get a bare machine to the point where `atyrode apply`
can run: Git, the pinned Nix, the repository at a reviewed revision, and the
pre-Nix repairs an installer would otherwise crash on. Then it relays: the
activation step is `atyrode apply` itself, and every durable surface of the
machine is that command's to converge. Bootstrap runs once per machine and
`atyrode apply` runs every time anything changes, so anything placed in
bootstrap after the handoff is a one-shot, correct on the day it ran and never
re-derived; state a machine can drift out of belongs on the side that runs
forever. The login shell proved it: bootstrap used to select the managed Zsh
with `chsh`, and `atyrode doctor system` could only send the operator back to
a one-shot script, so `atyrode apply` now converges it on every run.

The division reduces to two contracts. Whatever a bare machine is missing
before `atyrode apply` can run is bootstrap's. Whatever a machine can be
missing afterwards is detected by `atyrode doctor` and acted on by `atyrode
apply`. The macOS repair states are where the two meet rather than divide:
each can only be repaired before Nix exists, so the repair stays here, while
`atyrode doctor system` reads the same paths under its `bootstrap-residue`
check and names the `install.sh plan` that would repair what it finds.
Detection is shared, repair is not.

## Fresh-machine command

Run one command and choose from the registered presets compatible with the
machine:

```sh
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash
```

`get.sh` lists each preset with its description and capability breakdown from
`fleet/hosts.tsv`, then prompts for an explicit choice on the terminal. For
non-interactive Linux automation, pass the architecture-specific portable
profile and confirm the printed plan explicitly (`bash -s --
development-x86_64-linux --yes`). Portable profiles validate and bind the
invoking non-root user and canonical home directory at activation time and
reject a foreign-owned home or one that disagrees with the account database;
fixed machine profiles retain their declared repository identity. Bootstrap
validates explicit target names and never infers between portable, fixed,
desktop, or Mac configurations.

`get.sh` is deliberately thin: it verifies Git is present, clones the
repository to `~/nix-dotfiles` (`DOTFILES_DIR` overrides it; an existing
directory is reused only when its origin is this repository), and hands off to
the cloned `install.sh`, which owns every mutation. A reused directory is
never trusted at whatever revision it holds, because a stale `install.sh`
would otherwise decide what the freshly fetched entry point means: reuse is
routed through `install.sh --update`, and passing `--update`, `--allow-dirty`,
or `--allow-non-main` yourself is a reviewed decision about which revision to
activate that suppresses the implicit one.

A fetched-and-piped script is supported because three mitigations make it no
more trusting than a clone: the fetched script is function-wrapped so a
truncated download executes nothing, the confirmation prompt reads from the
terminal and a non-interactive run requires an explicit `--yes`, and the
bootstrap executes only from cloned, inspectable code. Cloning first and
running `bootstrap/install.sh apply --config <host>` yourself is equivalent.
The unmanaged prerequisites are Git and Bash; `curl` is needed only when `nix`
is absent, and `tar` plus `sha256sum` or `shasum` only for a fresh Nix
install.

## Phases and source policy

`preflight` is read-only: platform, explicit host selection, repository root,
raw and Git-resolved origin, the branch's relationship to cached
`origin/main`, required tools, and a warning when a previous apply was
interrupted. It rejects staged, tracked, and untracked changes. `plan` adds
the ordered repair, Nix, activation, and verification actions without creating
state, downloading an artifact, fetching Git, or moving a file. `apply`
repeats both and asks for confirmation; once Nix is available it uses the
packaged `atyrode apply` plan and activation, so the host registry and the
`nh` backend remain the only activation contract. `verify` re-runs the
verification apply already ran -- the recorded host receipt, then `atyrode
doctor` -- and reports what a machine is missing; converging any of it is
`atyrode apply`'s job, not another bootstrap phase.

Flakes are enabled only through the process-scoped `NIX_CONFIG`; bootstrap
does not append to a user-owned `nix.conf`. On standalone Linux it does write
the daemon-owned `/etc/nix/nix.conf`, once, to enrol the machine in the fleet
binary cache declared in `fleet/system-boundary.json`, installed with explicit
`sudo` and announced first, because the daemon trusts only `root` and a user
file cannot carry the cache's signing key. A refused write is a warning, never
a failed bootstrap: the machine converges either way and `atyrode doctor`
keeps naming the exact line. macOS is never touched; nix-darwin declares both
caches.

`--update` is the only way source moves: bootstrap never pulls implicitly.
If source changes it re-enters the fetched `install.sh` before writing the
interrupted-apply marker. Because `--update` already requires a clean tree, a
checkout parked on another branch is returned to `main` as part of the update
rather than refused -- moving `HEAD` leaves that branch and its commits
intact, and bootstrap prints the `git checkout` that goes back -- while a
local `main` holding commits absent from `origin/main` still stops it.
`--allow-dirty` and `--allow-non-main` are review acknowledgements for
intentional local work. A Git `url.*.insteadOf` rewrite cannot redirect the
accepted GitHub origin unnoticed.

`recover` is the exit when a state has no repair; `--help` says what it resets
on macOS. It prints the whole plan and changes nothing without confirmation,
and obeys the same two constraints as every repair: each file it removes is
archived first and the store volume is renamed rather than deleted, so the old
store keeps its data until the operator reclaims the space. On Linux the
managed environment lives in `/nix`, where removing it is destruction rather
than recovery, and `recover` refuses.

Bootstrap and `atyrode apply` share one narration contract -- the argv of
anything that acts, printed shell-quoted before it runs; silence for
read-only probes -- described in [the CLI's page](atyrode.md#what-the-cli-shows-while-it-runs).

## Nix installer decision

Fresh machines install upstream Nix 2.34.7 from the official
`releases.nixos.org` archive, whose SHA-256 values for x86_64/aarch64 Linux
and aarch64 Darwin are embedded in `install.sh`. Bootstrap downloads into a
private temporary directory, verifies the complete archive before extraction,
and only then runs the upstream installer non-interactively: single-user mode
on Linux, avoiding a daemon dependency on containers and other systemd-less
environments (one `sudo` to create `/nix` when absent); the required
multi-user mode on macOS. No channels are added and no shell profile edited,
because the flake and Home Manager own those. Existing Nix installations are
reused.

Upstream Nix won because it keeps the existing runtime, supports all three
repository targets, and provides official versioned release archives. The
[Lix installer](https://git.lix.systems/lix-project/lix-installer) and the
[Determinate installer](https://github.com/DeterminateSystems/nix-installer)
were rejected because each changes the Nix implementation or its defaults,
which is outside bootstrap hardening.

Bootstrap never removes a system-wide Nix install and never deletes a store,
because that could destroy state it cannot reconstruct. To uninstall a
bootstrap-created Nix, confirm that Nix was not present before the run and
follow the official
[multi-user uninstall procedure](https://nix.dev/manual/nix/2.22/installation/uninstall);
it is destructive and intentionally an operator action.

## Self-healing repairs

Bootstrap is the only supported deployment path, so a state it can recognise
is a state it repairs rather than one it reports. Every repair obeys two
constraints. **Idempotent:** detection is read-only and re-derived each run,
so a repeated run converges instead of compounding, and a repair whose work is
already done is not planned. **Reversible:** no repair may destroy state it
cannot reconstruct; where content would be lost it is archived first under
`${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/repairs/`, and every
repair appends the exact command that undoes it to `undo.log` there.

Detection runs in `preflight`, `plan` lists each repair, and `apply` performs
it with explicit privilege after confirmation, immediately before the step it
unblocks. Repairs are re-derived, never carried, so a step that changes the
machine cannot leave a plan describing the machine as it used to be: the one
that unblocks nix-darwin repairs a state the Nix installer itself creates, so
on a machine with no Nix yet it is re-derived after the installer runs and
stated as part of the install step.

| State | Repair |
| --- | --- |
| A pre-Nix shell rc backup blocks the installer | Restore it; keep any rewritten target as `<target>.nix-install-leftover` |
| Links anywhere under `/etc` resolve into a store that no longer exists | Remove them; links not owned by this toolchain are left alone |
| A TLS trust anchor this machine reads is not a usable CA bundle | Point it at the CA bundle in the Nix profile; archive the original |
| `/etc/fstab` names a `/nix` volume UUID that no longer resolves | Drop the line; archive the file first |
| An orphaned `Nix Store` volume exists | Rename it so the installer creates a fresh one |
| A shell rc file nix-darwin manages holds the Nix installer's block | Move it to `<file>.before-nix-darwin`, where nix-darwin puts it too |

**The rc backup.** The upstream installer copies every shell rc file it
touches to `<target>.backup-before-nix` and refuses to start when such a
backup exists and no longer matches its target, so an interrupted install
leaves a machine on which every retry fails late, and upstream's remediation
reads like an invitation to delete the only copy of the original. Bootstrap
evaluates the same condition, only while Nix is actually missing, and
restores the original; the rewritten target is kept beside it rather than
discarded, because proving byte for byte that it is the installer's own file
is not worth guessing wrong about on someone's `/etc`. A backup identical to
its target is left alone, matching upstream, because a completed install
legitimately leaves one behind.

**The volume.** The installer finds volumes by label, so a rename is enough to
route it onto its fresh-create path instead of the in-place encryption path
that crashes on a pre-existing volume, and unlike deletion it destroys nothing
and undoes with one command. `diskutil` renames through the mounted
filesystem, and an encrypted volume needs the passphrase the installer stored
in the root-only System keychain, so the lookup runs privileged: an
unprivileged read finds nothing and is indistinguishable from a volume whose
key is gone. When the key really is gone the volume cannot be renamed, and
leaving it labelled `Nix Store` routes the installer back onto the crash, so
it is deleted instead -- the store-database check has already proved no live
install is on it, and every path in a Nix store re-downloads. Deletion is the
one irreversible repair, so the run prints the reason it could not mount. A
populated store database means the volume is in use, not orphaned, and
suppresses the repair entirely.

**The `/etc` files nix-darwin refuses.** nix-darwin refuses to activate when
an `/etc` file it manages holds content it does not recognise, and the Nix
installer creates exactly that state by appending its block to the shell rc
files nix-darwin also owns. nix-darwin's own activation would move the file to
`<file>.before-nix-darwin` one step later; bootstrap performs that same move
before activation, so the end state matches a successful activation exactly
and the review happens in the plan instead of as an abort half an hour into a
build. Only a regular file carrying the installer's `# End Nix` marker is
moved, and where `<file>.before-nix-darwin` already exists it holds the
pre-nix-darwin original, which is worth more than the installer's copy, so
the copy is archived and the original left where it is. A file bootstrap did
not write is not bootstrap's to move, so activation can still refuse; that
refusal is read from the step's transcript, since the list nix-darwin prints
is generated from its own managed set, and a path that survives every move
bootstrap makes is one the operator owns, so the remedy is their command
rather than another run.

**The trust anchor.** The `/etc` sweep is recursive because
`/etc/ssl/certs/ca-certificates.crt` is where Nix reads its TLS trust anchors,
and a depth-limited sweep leaves a machine that installs Nix and then cannot
download anything through it; ownership, not depth, bounds it, so only links
resolving into the Nix store or through `/etc/static` are removed. Removing
the link is half the repair, because a nix-darwin generation leaves its
answer to "which file does Nix trust" in places the sweep never touches:
`NIX_SSL_CERT_FILE` in a login shell that outlived the generation,
`ssl-cert-file` in `/etc/nix/nix.conf`, and the `nix-daemon` launchd plist.
The condition is *usable*, not present: Nix loads the first probed path whose
`lstat` succeeds, so an absent path is harmless while a dangling link, an
empty file, and a non-certificate all fail every download with the same
error. Bootstrap reads each namer plus the paths Nix probes and points one
under `/etc` that is not a usable bundle at the CA bundle in the default Nix
profile, the one whose lifetime is not tied to a nix-darwin generation; a
regular file carries no ownership signal, so it is archived first. nix-darwin
reclaims the path at the next successful activation.

## Failure codes

Every operator-facing failure carries a stable `BOOT-E` code, the reason, and
the next action, printed together, so the table of codes is the script itself
(`fail` calls in [`bootstrap/install.sh`](../bootstrap/install.sh)).
`BOOT-E2xx` covers Nix installation and `BOOT-E3xx` the managed steps that
follow it -- evaluation, activation, and verification; `x99` in either range
means a state bootstrap does not recognise yet, reported with the transcript
path rather than as a bare exit status, because a code that does not exist
yet is the request for the repair that should. `BOOT-E201` through
`BOOT-E204` are classified from the upstream installer's own output, and each
names the repair that already handles it, so the remedy is to re-run
bootstrap.

**Findings are not failures.** `atyrode doctor` exits `69` when a family it
checks is incomplete. Bootstrap treats that as a *completed* bootstrap that
still has work to name: the machine activated, the host receipt matches, and
everything doctor reports is either converged by a later `atyrode apply` or a
decision only the operator can make, so bootstrap clears the interrupted-apply
marker, exits `0`, and prints what was found with the two commands that act on
it. Collapsing that state into a failure is what once reported a healthy Apple
Silicon machine as `BOOT-E399` -- offering to reset a Nix installation that
was fine -- because `gh` had not been configured yet. Any other non-zero
status from verification is a real failure and is classified normally.

The CA states (`E301`, `E302`) are re-derived by inspecting the trust-anchor
paths at failure time rather than parsed out of error prose, and each reports
what was observed -- the step failed, and the anchor is broken -- without
claiming one caused the other; `E301` names the repair that will run, `E302`
a path this toolchain does not own. `E304` is a configuration that did not
build: nothing was activated, the machine is unchanged, and the only remedy
that can work is to fix the configuration, since the same build fails on
every machine. That classifier runs after the CA checks, because a machine
that cannot verify TLS also fails to build, and that failure is repairable
here.

## Run logs

`apply` writes a timestamped transcript per run to
`${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/logs/<UTC>-apply.log`
and the upstream installer's own output beside it. Off a terminal it also
captures one file per managed step (`-evaluation`, `-activation`,
`-verification`). A managed step's stdio is also a conversation -- activation
asks for sudo, for Touch ID behind an identity ceremony, and whether to
provision each surface it found unconfigured, and the CLI gates every one of
those on stdin and stdout both being a terminal -- so capturing the stream
would answer no to all of them. Bootstrap captures only where there is no
terminal to lose, which is exactly where there is nobody to ask; on a
terminal the run log records that the step streamed to the operator. That is
why the classifier reads a transcript when one exists and machine state
otherwise: only `BOOT-E303` needs the step's own words, because the paths
nix-darwin refuses to overwrite are printed by nix-darwin and nowhere else,
and on a terminal those words are on the operator's screen.

Failures print the log path and append a diagnostics block naming the state a
diagnosis needs -- the resolved `nix`, `PATH`, each TLS trust anchor with the
namer that produced it and what it actually is -- so an unrecognised code
arrives with its evidence rather than costing another run. Logging never fails
a run: a machine too broken to write state is still allowed to attempt its own
repair.

## Provisioning surfaces

Activation installs the machine's declared state. What it cannot install is
anything that needs a secret or a decision -- a key that must be minted on an
operator device, forty gigabytes of disk, enrollment with a service. Those are
the provisioning surfaces, each declared once in
[`fleet/provisioning.json`](../fleet/provisioning.json) with the command that
configures it and what accepting commits the machine to, and `atyrode apply`
reviews every one of them after activating (see [the CLI's
page](atyrode.md#after-activation)). Bootstrap's part is to not get in the
way: it runs each managed step on the operator's own stdio so the offers reach
a human who can answer them, and names no provisioning command of its own --
one prompt from one place, rather than two layers asking the same question
with different wording.

## Colour

Colour is a reading aid, never data. It is on only where the stream is a
terminal and the environment permits it -- `NO_COLOR` honoured, `TERM=dumb`
excluded -- so a redirected run, a pipe, and the check harness all receive
plain bytes, and each stream is decided separately, so `plan | less` stays
plain while a failure printed beside it stays red. The palette is the CLI's,
because one machine should speak with one voice.

## Interrupted-apply marker and recovery

Bootstrap state lives under `${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/`:
`dotfiles-config` (the host receipt), `install-interrupted`, and `bootstrap/`
holding `logs/` and `repairs/` (the archived files and `undo.log`).

`apply` writes `install-interrupted` immediately before its first mutating
step. The marker holds two lines, `config=<host>` and `started=<ISO-8601
UTC>`, and is removed only after verification succeeds. While it exists,
`plan` and `apply` print a warning naming the configuration and start time;
`plan` only warns, and a successful `apply` clears it. State is safe after an
interruption: recover by re-running `./bootstrap/install.sh apply --config
<host>`. Bootstrap never rolls back a successfully activated generation; that
is `atyrode rollback`.

## Verification coverage

`checks/atyrode/bootstrap/` drives the script against temporary homes and
repositories, and `checks/atyrode/get-sh.nix` the fetched entry point. The
macOS repairs are covered on every platform: the states they fix cannot be
built on a Linux runner, so the check forces the platform through a test-hook
override and stages the machine behind `diskutil`, `launchctl`, `security`,
and `plutil` stand-ins -- including an `/etc` reached through a symlink, a
keychain that refuses an unprivileged read, and a binary launchd plist --
because a fixture that is easier than the platform tests nothing. The
login-shell contract is covered in `checks/atyrode/atyrode-apply.nix` against
the real CLI that converges it, since bootstrap's harness could only ever
drive a stand-in for `atyrode`.
