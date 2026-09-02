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

**The operator identity** (`&alex` in `.sops.yaml`) is the one key that reads
everything and the only key that ever edits: `sops secrets/<file>.yaml` opens
a file in `$EDITOR` and re-encrypts it on save. Where its private half lives
is the operator's decision; Bitwarden already holds the break-glass copy.
Nothing in this repository or the CLI reads it. `~/.config/sops/age/keys.txt`,
the file sops itself reads, is where it is expected on the workstation.

**A machine identity** is the age key one machine decrypts with at
activation, generated on that machine and never copied anywhere:

| Activation | Key | Held by |
| --- | --- | --- |
| Home Manager (standalone) | `~/.config/sops/age/machine.txt` | the user, mode 0600 under a mode-0700 directory |
| nix-darwin, NixOS, NixOS-WSL | `/var/lib/sops-nix/machine.txt` | root, mode 0600 under a mode-0700 directory; its public recipient is published at `/etc/atyrode/machine.pub` so `doctor` can read it without elevating |

The Home Manager path is deliberately not `keys.txt`: on the operator's
workstation that file is the operator identity, and an activation must never
be able to decrypt as the operator. SSH host keys are not used either; an
explicit key is simpler to name, to reason about, and to revoke.
[`modules/secrets.nix`](../modules/secrets.nix) is where sops-nix is told these
paths, once for all three activation kinds.

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
   `sops updatekeys` on each of them with the operator key.
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
same is true of the operator key, for every file.

This is the price of publishing ciphertext, and it was decided with it (ADR
0008): a leaked machine key costs exactly what a leaked vault session would,
and it is the reason a machine only ever reads the files it needs.
