# Bootstrap

The bootstrap is the only supported path from an unmanaged machine to a
registered dotfiles host. It is conservative because it runs before the
managed environment is known to work.

## Bootstrap once, apply forever

Bootstrap's job is to get a bare machine to the point where `atyrode apply`
can run: Git, the pinned Nix, the repository at a reviewed revision, and the
pre-Nix repairs an installer would otherwise crash on. Then it relays. The
activation step is `atyrode apply` itself rather than a bootstrap
reimplementation of it, and every durable surface of the machine is that
command's to converge.

The split is not a preference about where code lives. Bootstrap runs once per
machine; `atyrode apply` runs every time anything changes. Anything placed in
bootstrap after the handoff is therefore a one-shot — correct on the day it
ran and never re-derived afterwards — so state a machine can drift out of
belongs on the side that runs forever, and only what has to precede
`atyrode apply` belongs here.

The login shell is the case that proved it. Bootstrap used to register the
managed Zsh in `/etc/shells` and select it with `chsh`, and the remediation
`atyrode doctor system` printed for that state read "rerun install.sh apply
with privilege to register and select the managed Zsh path" — a convergence
tool deferring to a one-shot script. Doctor detected the drift correctly and
then had nothing of its own that could act on it. `atyrode apply` now
converges the login shell on every run, so there is no `login-shell.incomplete`
marker any more: a marker only records that one run fell short, and retrying
the convergence on every apply is strictly stronger than a record that one
particular `install.sh verify` could erase.

The division reduces to two contracts. Whatever a bare machine is missing
before `atyrode apply` can run is bootstrap's. Whatever a machine can be
missing afterwards is detected by `atyrode doctor` and acted on by
`atyrode apply`.

The macOS repair states are the case where the two contracts meet rather than
divide. Each of them -- a shell rc backup never restored, an `/etc` profile
file where nix-darwin owns a link, an `/etc` link into a store path that is
gone, a TLS anchor Nix cannot read, an `fstab` line naming a volume that no
longer resolves -- can only be repaired before Nix exists, so the repair stays
here. Nothing re-examined them afterwards, which meant a machine that
installed successfully years ago carried them unseen; `atyrode doctor system`
now reads the same paths under the `bootstrap-residue` check and names the
`install.sh plan` that would repair what it finds. Detection is shared,
repair is not.

## Fresh-machine command

Run one command and choose from the registered presets compatible with the
machine:

```sh
curl -fsSL https://raw.githubusercontent.com/atyrode/dotfiles/main/get.sh | bash
```

`get.sh` lists each preset with its description and capability breakdown from
`fleet/hosts.tsv`, then prompts for an explicit choice on the terminal.
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
git clone https://github.com/atyrode/dotfiles.git "$HOME/nix-dotfiles" && "$HOME/nix-dotfiles/bootstrap/install.sh" apply --config development-x86_64-linux
```

The unmanaged prerequisites are Git and Bash. `curl` is needed only when `nix`
is absent, and `tar` plus `sha256sum` or `shasum` only for a fresh Nix
install.

## Phases and source policy

The phases are independently callable:

```sh
./bootstrap/install.sh preflight --config development-x86_64-linux
./bootstrap/install.sh plan --config development-x86_64-linux
./bootstrap/install.sh apply --config development-x86_64-linux
./bootstrap/install.sh verify --config development-x86_64-linux
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
user-owned `nix.conf`. On standalone Linux it does write the daemon-owned
`/etc/nix/nix.conf`, once, to enrol the machine in the fleet binary cache
declared in `fleet/system-boundary.json`: two `extra-` lines appended
below whatever the installer wrote, installed with explicit `sudo` and
announced first. The daemon trusts only `root`, so a user file cannot carry
the cache's signing key; the daemon's own file is the one place it can live.
A refused write is a warning, never a failed bootstrap — the machine
converges either way and `atyrode doctor` keeps naming the exact line. macOS
is never touched: nix-darwin declares both caches. `verify` re-runs the
verification step apply already ran: the recorded host receipt, then
`atyrode doctor`, the aggregate over the host, system, git, tools, and
provisioning families. It reports what a machine is missing; converging any
of it is `atyrode apply`'s job, not another bootstrap phase.

`recover` is the exit when a state has no repair. Bootstrap converges on the
states it can name, and a machine that keeps reporting an unrecognised one is
a machine the operator should be able to reset without hand-running commands
from someone else's manual. On macOS it resets what a dead nix-darwin
generation owns — stops the `nix-daemon` and removes its LaunchDaemon,
removes `/etc/nix`, unmounts and renames the `Nix Store` volume, puts back
every `/etc` file a previous generation left broken — then installs Nix fresh
and activates normally. It prints the whole plan and changes nothing without
confirmation.

Recovery obeys the same two constraints as every repair. Each file it removes
is archived under
`${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/repairs/` first, and
the volume is renamed rather than deleted, so the old store keeps its data
until the operator reclaims the space. The store itself is the one thing worth
destroying cheaply — it is a content-addressed cache and every path in it is
re-fetchable — but a rename is enough to route the installer onto its
fresh-create path, so bootstrap takes that instead. On Linux the managed
environment lives in `/nix`, where removing it is destruction rather than
recovery, and `recover` refuses.

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

## Every command is shown before it runs

Bootstrap and `atyrode apply` print the argv of anything that changes this
machine, reaches the network, or takes real time, on the line before running
it:

```
$ nix run /Users/alex/nix-dotfiles#atyrode -- apply macbook --repo /Users/alex/nix-dotfiles --git-auth-mode ssh --restart-shell
$ sudo -- chsh -s /run/current-system/sw/bin/zsh alex
$ sh /tmp/atyrode-nix.XXXX/nix-2.34.7-aarch64-darwin/install --daemon --yes --no-channel-add --no-modify-profile
```

The rendering is shell-quoted, so a line can be pasted back verbatim to repeat
that step by hand. This covers the Nix download and installer, the checkout
fetch and fast-forward, every `atyrode` invocation, every privileged repair,
the `nh` activation itself, and each provisioning ceremony.

Read-only probing stays silent by design. Printing every `command -v` and
`show-ref` would bury the handful of commands that actually act, which is the
opposite of being able to follow what is happening.

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

Detection runs in `preflight`. `plan` lists each repair, and `apply` performs
it with explicit privilege after confirmation, immediately before the step it
unblocks. Three of the six repairs exist to unblock the upstream installer,
so they are only evaluated while Nix is missing. The `/etc` sweep and the
trust-anchor restore are not among them: they repair Nix itself, run whether
or not Nix is installed, and a machine whose Nix cannot verify TLS is exactly
the machine that needs them.

The sixth is the other way around: it unblocks nix-darwin, and the state it
repairs is one the Nix installer creates. On a machine that has no Nix yet it
does not exist at preflight, so it is re-derived after the installer runs and
the plan states it as part of the install step. Repairs are re-derived, never
carried, precisely so a step that changes the machine cannot leave a plan
describing the machine as it used to be.

| State | Repair |
| --- | --- |
| A pre-Nix shell rc backup blocks the installer | Restore it; keep any rewritten target as `<target>.nix-install-leftover` |
| Links anywhere under `/etc` resolve into a store that no longer exists | Remove them; links not owned by this toolchain are left alone |
| A TLS trust anchor this machine reads is not a usable CA bundle | Point it at the CA bundle in the Nix profile; archive the original |
| `/etc/fstab` names a `/nix` volume UUID that no longer resolves | Drop the line; archive the file first |
| An orphaned `Nix Store` volume exists | Rename it so the installer creates a fresh one |
| A shell rc file nix-darwin manages holds the Nix installer's block | Move it to `<file>.before-nix-darwin`, where nix-darwin puts it too |

The volume repair renames rather than deletes. The installer finds volumes by
label, so a rename is enough to route it onto its well-tested fresh-create
path instead of the in-place encryption path that fails on a pre-existing
volume — and unlike deletion, it destroys nothing and undoes with one command.
The orphaned volume keeps its data until the operator reclaims the space.

`diskutil` renames an APFS volume through its mounted filesystem and refuses
an unmounted one with `Volume must be mounted`. Recovery unmounts to free
`/nix` for the volume the installer creates, so the next run is guaranteed to
meet an unmounted volume: mounting is part of renaming, and the volume is left
exactly as it was found.

An encrypted volume is locked when it is unmounted, and mounting it needs the
passphrase the installer stored in the System keychain under the volume UUID.
That keychain is root-only, so the lookup runs with the same privilege
upstream's `create-darwin-volume.sh` uses; reading it unprivileged finds
nothing and is indistinguishable from a volume whose key is gone. When the key
really is gone the volume cannot be mounted, therefore cannot be renamed, and
leaving it labelled `Nix Store` routes the installer back onto the path that
crashes. It is deleted instead — the store-database check has already proved
no live install is on it, and every path in a Nix store re-downloads. Deletion
is the one irreversible repair, so the run prints the reason it could not
mount rather than only what it did.

nix-darwin refuses to activate when an `/etc` file it manages holds content it
does not recognise, and prints the paths it refused. The Nix installer creates
exactly that state: it appends its block to the shell rc files nix-darwin also
owns. The refusal is a review gate rather than a disagreement about the
outcome — nix-darwin's own `/etc` activation moves any conflicting file to
`<file>.before-nix-darwin` one step later. Bootstrap performs that same move
before activation, so the end state matches a successful activation exactly
and the review happens in the plan instead of as an abort half an hour into a
build.

Only a regular file carrying the installer's `# End Nix` marker is moved. A
link is either nix-darwin's own path into `/etc/static` or someone else's
redirection, and neither is a file bootstrap wrote. Where
`<file>.before-nix-darwin` already exists it holds the pre-nix-darwin
original, which is worth more than the installer's copy: that copy is archived
under the repairs directory and the original is left where it is.

A file bootstrap did not write is not bootstrap's to move, so activation can
still refuse. That refusal is read from the transcript of the step that
reported it — the list nix-darwin prints is generated from its own managed
set, which is a fact no inspection here could establish — and each named path
is checked to be still present before it is reported. Every file bootstrap
does move is already moved by then, so a name that survives to that point is
one the operator owns, and the remedy is their command rather than another
run.

The `/etc` sweep is recursive because nix-darwin owns nested paths the same
way it owns top-level ones. `/etc/ssl/certs/ca-certificates.crt` is the one
that matters most: it is where Nix reads its TLS trust anchors, so a
depth-limited sweep leaves a machine that installs Nix successfully and then
cannot download anything through it. Ownership, not depth, is what bounds the
sweep — only links resolving into the Nix store or through `/etc/static` are
removed, at any depth.

Removing that link is only half the repair. Which file Nix trusts is a machine
fact rather than a constant, and a nix-darwin generation leaves its answer
behind in places the sweep never touches: `NIX_SSL_CERT_FILE` exported by a
login shell that outlived the generation, `ssl-cert-file` in
`/etc/nix/nix.conf`, and the `nix-daemon` launchd plist — the daemon, not the
client, is what fetches from the binary cache, and that plist is routinely
stored as binary, so it is decoded with `plutil` rather than grepped. Whatever
named the path still names it after the link is gone.

The condition is **usable**, not present. Nix does not look for this file, it
loads it: `getDefaultSSLCertFile` takes the first of
`/etc/ssl/certs/ca-certificates.crt` and the profile bundle for which
`pathAccessible` — an `lstat` — succeeds, then hands it to curl. An absent
path is therefore harmless, because Nix skips it and falls through to the
profile bundle. A dangling link, an empty file, and a file that is not a
certificate bundle are all selected and all fail every download with the same
error naming the same path.

So bootstrap reads each namer plus the paths Nix probes, and for one under
`/etc` that is not a usable bundle, points it at
`/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt` — the one CA bundle
on a Nix machine whose lifetime is not tied to a nix-darwin generation. A link
is removed under the ownership rule; a regular file carries no ownership
signal, so it is archived first and the undo command restores it byte for
byte. nix-darwin reclaims the path at the next successful activation.

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
| `BOOT-E214` | A TLS trust anchor could not be restored |
| `BOOT-E215` | The orphaned volume could neither be mounted to rename nor deleted |
| `BOOT-E216` | A shell rc file could not be moved aside for nix-darwin |
| `BOOT-E220` | Recovery could not archive or remove the nix-daemon LaunchDaemon |
| `BOOT-E221` | Recovery could not archive or remove `/etc/nix` |
| `BOOT-E299` | The upstream installer failed in a way bootstrap does not recognise yet |
| `BOOT-E301` | A managed step failed and a TLS trust anchor this machine reads is not a usable CA bundle |
| `BOOT-E302` | The same, but the path is not bootstrap's to replace |
| `BOOT-E303` | nix-darwin refused to overwrite an `/etc` file whose content is not bootstrap's to move |
| `BOOT-E304` | The configuration did not build, so nothing was activated and the machine is unchanged |
| `BOOT-E399` | A managed step failed in a way bootstrap does not recognise yet |

`BOOT-E2xx` covers Nix installation, `BOOT-E3xx` the managed steps that follow
it — evaluation, activation, and verification. `BOOT-E201` through `BOOT-E204`
are classified from the upstream installer's own output, and each names the
repair that already handles it, so the remedy is to re-run bootstrap.

### Findings are not failures

`atyrode doctor` exits `69` when a family it checks is incomplete. Bootstrap
treats that as a **completed** bootstrap that still has work to name: the
machine activated, the host receipt matches, and everything doctor reports is
either converged by a later `atyrode apply` or is a decision only the operator
can make. Bootstrap clears the interrupted-apply marker, exits `0`, and prints
what was found along with the two commands that act on it.

Collapsing that state into a failure is what once reported a healthy Apple
Silicon machine as `BOOT-E399` — sending the operator to the issue tracker and
offering to reset a Nix installation that was fine — because `gh` had not been
configured yet. Any other non-zero status from the verification step remains a
real failure and is classified normally.

The `BOOT-E3xx` CA states are re-derived by inspecting the trust-anchor paths
at failure time rather than parsed out of error prose. Bootstrap reads every
namer — the environment, `/etc/nix/nix.conf`, the daemon plist, and the fixed
list Nix probes when nothing names one — and reports the first that is not
usable, along with which namer produced it. `BOOT-E301` means bootstrap can
act on it, and its remedy states which repair will run: restoring the file
when a profile CA bundle is available, removing the link when it is not.
`BOOT-E302` means the path is a dangling link this toolchain does not own, so
the next action belongs to the operator. Each code reports what was observed —
the step failed, and the anchor is broken — without claiming one caused the
other.

A configuration that fails to build reached that same wrong ending by another
route. The backend builds the closure before it switches, so a build error
never touches the machine: nothing is activated, and the Nix installation
bootstrap offered to reset was working correctly the whole time. `BOOT-E304`
names that state, reports which derivation failed, and says the machine is
unchanged. Its remedy is the only one that can work, because the same build
fails on every machine: read the build error and fix the configuration. The
classifier runs after the CA checks and never before them, since a machine that
cannot verify TLS also fails to build, and that failure is repairable here.

## Run logs

`apply` writes a timestamped transcript per run and the upstream installer's
own output beside it. Off a terminal it also captures one file per managed
step:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/bootstrap/logs/
├── 20260831T161500Z-apply.log
├── 20260831T161500Z-apply-nix-installer.log
├── 20260831T161500Z-apply-evaluation.log
├── 20260831T161500Z-apply-activation.log
└── 20260831T161500Z-apply-verification.log
```

A managed step's output is evidence, and its stdio is also a conversation.
Activation asks for sudo, for the vault password, and whether to provision
each surface it found unconfigured; the CLI gates every one of those on stdin
and stdout both being a terminal. Capturing the stream answers no to all of
them, so bootstrap captures only where there is no terminal to lose — which is
exactly where there is nobody to ask. On a terminal the run log records that
the step streamed to the operator rather than a copy of what it said.

That is why the classifier reads a transcript when one exists and machine
state otherwise. The trust-anchor and volume codes were always re-derived from
the machine; only `BOOT-E303` needs the step's own words, because the paths
nix-darwin refuses to overwrite are printed by nix-darwin and nowhere else. On
a terminal those words are on the operator's screen, which is the one place a
transcript was never needed.

Failures print the log path. Logging never fails a run: a machine too broken
to write state is still allowed to attempt its own repair.

Every failure also appends a diagnostics block naming the state a diagnosis
needs — the resolved `nix`, `PATH`, each TLS trust anchor with the namer that
produced it, and what each one actually is. A machine state that needs a round
trip to diagnose costs a release cycle, and these facts are cheap to collect
while the failure is still on the machine, so an unrecognised code arrives
with its evidence rather than requiring another run to produce it.

## What bootstrap does not do itself

Activation installs the machine's declared state. What it cannot install is
anything that needs a secret or a decision — a vault password, forty gigabytes
of disk, enrollment with a service. Those are the CLI's provisioning
ceremonies, and `atyrode apply` reviews every one of them after activating.

Bootstrap's part is to not get in the way of that. It runs each managed step
on the operator's own stdio so the offers reach a human who can answer them,
and it names no provisioning command of its own — one prompt from one place,
rather than two layers asking the same question with different wording.

## Provisioning surfaces

The surfaces below are the ones a managed machine may have and does not have
to. None is implied by activation, because each one costs the machine
something it cannot take back silently:

| Surface | What accepting commits this machine to |
| --- | --- |
| Babel session archive (`atyrode provision babel`) | The vault password once, after which the hourly timer publishes this machine's session archives |
| Git identity (`atyrode provision git`) | The vault password, plus an ed25519 authentication and signing keypair materialised on disk and loaded into the agent |
| omp seed drift (`atyrode-omp-seed resolve`) | Nothing beyond the local plain-omp settings file: repository defaults are restored over local edits, with no secret and no network call |
| generated agent context (`atyrode context render`) | Nothing beyond a file under `~/.config/agents`: this machine's facts under the operator policy. It asks `gh` and `clever` for their session state (read-only, bounded), stores no secret, and downloads nothing; apply renders it itself, so this surface is only ever pending between applies |
| local-qwen (`atyrode runtime provision local-qwen`) | Roughly forty gigabytes of downloads and a built container image serving a model from the local GPU |
| manifold-agent (`atyrode runtime provision manifold-agent`) | Enrollment with the self-hosted manifold hub: an owner key read from the vault, one call to the master, and a machine token stored on disk |

Three rules govern all of them, so that a surface is data rather than a
dialogue somebody has to design again:

- **On a terminal each is an offer.** The implication is stated, the question
  is a `y/N` defaulting to no, and accepting runs exactly the command the
  offer names in that terminal — so what apply does and what the operator
  would have typed are the same thing.
- **Off a terminal each is a name.** The surface and the command that
  configures it are printed and nothing runs. A stream with nobody on it
  cannot consent to a vault password or forty gigabytes.
- **A decline is recorded.** The record is per machine and per surface, so a
  surface refused once is not offered again on the next apply. Asking a second
  time is how a prompt becomes noise, and noise is answered without reading.

A declined surface is not a failed run. The machine activated; it is simply
not archiving, signing, serving, or enrolled yet. The way back in is the
command the offer named: it is the same command the day of the decline and a
year later, it does not require finding and editing the record, and running it
clears the record as a side effect of the surface becoming configured.

## Colour

Colour is a reading aid, never data. It is on only where the stream is a
terminal and the environment permits it — `NO_COLOR` honoured, `TERM=dumb`
excluded — so a redirected run, a pipe, and the check harness all receive
plain bytes. Each stream is decided separately, so `plan | less` stays plain
while a failure printed beside it stays red.

The palette is the CLI's, because one machine should speak with one voice:
bold for headings and step numbers, dim for labels and asides, cyan for a path
or a value, bold cyan for a command meant to be retyped, yellow for a warning,
green for a repair that succeeded, red for a failure.

## Interrupted-apply marker and recovery

Bootstrap state lives under:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/
├── dotfiles-config
├── install-interrupted
└── bootstrap/
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
./bootstrap/install.sh apply --config <host>
```

Bootstrap never rolls back a successfully activated generation. Use the
standard `home-manager generations` (or nix-darwin) rollback when a previous
generation is needed.

## Verification coverage

`checks/atyrode/bootstrap/` uses temporary homes and repositories, covering the
read-only plan, fresh and repeated application, source updates, origin and
revision defenses, installer failures and their classification into codes,
every self-healing repair and its undo journal, the recovery phase and its
refusal to act without confirmation, the interrupted-apply marker contract,
unsafe state types, production-only test-hook gating, whether a managed step
is captured or handed the operator's own stdio, the
colour gate in both directions, and idempotence. The macOS repairs are covered
on every platform: the states
they fix cannot be built on a Linux runner, so the check forces the platform
through a test-hook override and stages the machine behind `diskutil`,
`launchctl`, `security`, and `plutil` stand-ins — including a `/etc` that is
reached through a symlink, a keychain that refuses an unprivileged read, and a
launchd plist that is not readable as text, because a fixture that is easier
than the platform tests nothing. The scenarios are grouped into seven
derivations over the shared fixtures in `checks/atyrode/bootstrap/harness.nix`
— `bootstrap-lint`, `bootstrap-core`, `bootstrap-darwin-etc`,
`bootstrap-darwin-trust`, `bootstrap-darwin-volumes`,
`bootstrap-darwin-codes-recover`, and `bootstrap-terminal` — so a failure in
one group rebuilds only that group instead of every scenario. They all run
natively in all three CI jobs.

The login-shell contract is no longer among them. It is covered in
`checks/atyrode/atyrode-apply.nix`, against the real CLI that now converges it.
Bootstrap's harness could only ever drive a stand-in for `atyrode`, so what a
login-shell scenario proved there was the stand-in's behaviour rather than the
contract's.

`checks/atyrode/get-sh.nix` covers the fetched entry point: the usage and missing-Git
failures, refusal to reuse a foreign target directory, the streamed
piped-stdin handoff to the cloned `install.sh` with `--yes` and recorded
arguments, the implicit `--update` on a reused checkout and its suppression by
each explicit source acknowledgement, the refusal to proceed without a
terminal or `--yes`, and the `DOTFILES_DIR` override with forwarded install
arguments.
