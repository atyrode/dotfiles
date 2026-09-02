# Secrets and their audience

Secrets are age-encrypted YAML files under [`secrets/`](../secrets/README.md),
committed to this public repository, and decrypted at activation by
[sops-nix](https://github.com/Mic92/sops-nix) on every kind of host. The
decision and its alternatives are
[ADR 0008](adr/0008-fleet-shape-and-substrate.md), which supersedes
[ADR 0005](adr/0005-no-declarative-secret-manager.md).

## The audience model

[`.sops.yaml`](../.sops.yaml) at the repository root is the only place a
secret's readers are written down. It names public age recipients and the
files each may read:

- `secrets/shared.yaml` — every registered machine, and the operator.
- `secrets/<host>.yaml` — that one machine, and the operator.

A reader of the repository learns which secrets exist and which machines may
read them; never a value. Adding a machine to a file's audience and running
`sops updatekeys secrets/<file>.yaml` re-encrypts it for the new recipient;
removing one and running the same command means the next revision is
unreadable to it.

## Two identities

**The operator identity** is two recipients in `.sops.yaml`, and the only
keys that ever edit: `sops secrets/<file>.yaml` opens a file in `$EDITOR` and
re-encrypts it on save.

- `&alex` is the daily identity. It is minted by
  [`age-plugin-se`](https://github.com/remko/age-plugin-se) inside the Secure
  Enclave of the registered Mac (`atyrode operator init`), and every
  decryption -- so every edit -- asks for Touch ID or the login passcode.
  `~/.config/sops/age/keys.txt` holds a handle the enclave understands, not
  key material: the private half cannot be extracted, copied, or backed up,
  which is exactly why there is a second recipient.
- `&alex-recovery` is the software key that used to be the only operator key.
  Its only copy is the break-glass note in Bitwarden; it is not on any disk,
  and nothing in this repository or the CLI reads it. It is a recipient of
  every file so that losing the Mac costs one `sops updatekeys` and nothing
  more.

The `security` capability installs `sops` on every fleet member and the
plugin on the Mac alone, and points `SOPS_AGE_KEY_FILE` at
`~/.config/sops/age/keys.txt` so sops reads the file the ceremony writes on
every platform (macOS would otherwise look under `~/Library`). The plugin does
build on Linux, but its closure there is a 2 GiB Swift runtime, and a Linux
host has no identity to decrypt with as the operator anyway: **every sops
edit happens on the Mac**. A Linux host with `sops` can inspect what
activation decrypted for it with its machine key
(`SOPS_AGE_KEY_FILE=<machine key> sops -d secrets/<host>.yaml`) and nothing
else.

**A machine identity** is the age key one machine decrypts with at
activation, generated on that machine and never copied anywhere:

| Activation | Key | Held by |
| --- | --- | --- |
| Home Manager (standalone) | `~/.config/sops/age/machine.txt` | the user, mode 0600 under a mode-0700 directory |
| nix-darwin, NixOS, NixOS-WSL | `/var/lib/sops-nix/machine.txt` | root, mode 0600 under a mode-0700 directory; its public recipient is published at `/etc/atyrode/machine.pub` so `doctor` can read it without elevating |

The Home Manager path is deliberately not `keys.txt`: on the Mac that file
is the operator identity, and an activation must never be able to decrypt as
the operator. SSH host keys are not used either; an
explicit key is simpler to name, to reason about, and to revoke.
[`modules/shared/secrets.nix`](../modules/shared/secrets.nix) is where sops-nix is told these
paths, once for all three activation kinds.

## Enrolling the operator (the Mac, once)

The ceremony runs on the Mac with the operator's finger and nowhere else;
`atyrode operator` refuses on every other host, and `doctor provisioning`
reports the `operator-identity` surface as `not-applicable` there.

1. `atyrode apply`, so the `security` capability has installed `sops` and
   `age-plugin-se`. If `~/.config/sops/age/keys.txt` still holds the software
   key, move it aside first (the Bitwarden note is its copy of record);
   `operator init` refuses to overwrite any existing file and says so.
2. `atyrode identity init`: the Mac's own machine identity, root-owned as on
   every system host.
3. `atyrode operator init`: says that Touch ID will prompt, runs the one
   announced `age-plugin-se keygen --access-control=any-biometry-or-passcode`,
   asserts the modes, and prints `- &alex age1se1...`.
4. Paste the two lines into `.sops.yaml`: the machine's under `machines`, the
   operator's into the `&alex` slot under `keys`, and uncomment `*alex` (and
   `*alex-aarch64-darwin`) in the creation rules. Once files exist under
   `secrets/`, `sops updatekeys secrets/*.yaml` re-encrypts them to the new
   recipients; a file created afterwards is encrypted to them from the start.
   `&alex-recovery` stays in every rule.
5. Commit and push. From here every edit is `sops secrets/<file>.yaml` on the
   Mac, with Touch ID.

`atyrode operator show` prints the recipient and whether it is registered.
Neither verb ever reads past the `# public key:` comment the plugin writes:
the identity line is never printed, and `age-keygen -y` could not read it
anyway.

**A lost or replaced Mac** costs no rotation. The private half was never
extractable, so nothing leaked with the machine; the enclave key is simply
gone. Recover the software key from the Bitwarden note to a temporary
`SOPS_AGE_KEY_FILE`, run the ceremony above on the new Mac, replace the
`&alex` recipient with the new one, `sops updatekeys secrets/*.yaml`, and
delete the temporary file. The one thing that would force a rotation of
every value is the recovery key itself leaking, which is why it lives in
exactly one place.

## Enrolling a machine

1. On the machine: `atyrode identity init`. It generates the key if absent
   (announcing each `sudo` step on a system host), prints the one line to add
   to `.sops.yaml` — `- &<host> age1...` — and the `sops updatekeys` commands
   that follow. `atyrode apply` offers this on a machine that has no key yet,
   and `atyrode doctor provisioning` reports the `machine-identity` surface:
   no key, a key the audience file does not name (with that exact line), or
   registered.
2. In this repository: fill the host's slot in `.sops.yaml` (every registered
   host has one, commented out until its ceremony has run), uncomment its
   reference in the creation rules for the files it may read, and run
   `sops updatekeys` on each of them on the Mac, with Touch ID.
3. Commit and push; the machine reads its secrets on the next apply.

`atyrode identity show` prints the recipient and whether it is registered;
`--json` is the same record as data. Neither ever prints the private half, and
neither does `init`: `age-keygen` writes the key and only its public half is
read back, with `age-keygen -y`.

## Declaring a secret

A secret is a `sops.secrets.<name>` entry in the host's Nix configuration,
read from the default file (`secrets/<host>.yaml` when the repository has one,
`secrets/shared.yaml` otherwise) or from an explicit `sopsFile`. sops-nix
places the plaintext at a mode-0600 path at activation (`/run/secrets/<name>`
on system hosts, under `$XDG_RUNTIME_DIR` for standalone Home Manager) and
never in the Nix store. With no secret declared, sops-nix does nothing at
activation and never reads the file, which is why an empty fleet converges on
every host today.

## Revocation and rotation

Two different things happen when a key is gone.

**A machine leaves the fleet** (decommissioned, or its key lost): remove its
recipient from `.sops.yaml` and run `sops updatekeys` on the files it could
read. From that revision on, the machine cannot decrypt anything new.

**A machine key leaks**: revoke as above, then **rotate every value that key
could read** — the values, not just the audience. Ciphertext history is
permanent: every revision of `secrets/*.yaml` ever pushed stays in Git, and a
leaked key decrypts every past revision it was a recipient of. Re-encrypting
protects the future; only new values protect what was already published. The
same is true of the recovery key, for every file. The Secure Enclave key is
the one recipient this cannot happen to: it has no exportable form, so a lost
Mac is the first case above, never this one.

This is the price of publishing ciphertext, and it was decided with it (ADR
0008): a leaked machine key costs exactly what a leaked vault session would,
and it is the reason a machine only ever reads the files it needs.

## Plaintext never reaches a remote

Encryption covers what goes through sops. The mistake it cannot cover is a
value pasted by hand: a token in a config file, a key in a doc. Two scans
catch that, with the same scanner ([gitleaks](https://github.com/gitleaks/gitleaks))
so they agree on what a credential looks like.

The first is a `pre-commit` hook that Home Manager installs on every machine
([`modules/home/git/pre-commit`](../modules/home/git/pre-commit)). Git's hooks path is global
here, so it runs in **every repository you commit to**, not only this one: a
credential-shaped stage is refused before it exists in any history, with the
file, the line, and the rule named and the value redacted. A deliberate
exception is `git commit --no-verify`. The hook then hands over to the
repository's own `pre-commit`, which a global hooks path would otherwise hide
from git; the `pre-push` hook does the same for a repository's own `pre-push`.

The second is the `secret-shapes` check in CI, which scans the whole tree on
every push (the docs-only fast path included) and is the backstop for a commit
that skipped the hook or came from a machine without it. It is also the one
place that knows what a sops file must look like: anything under `secrets/`
that lacks a `sops:` block or `ENC[...]` values fails the build.
