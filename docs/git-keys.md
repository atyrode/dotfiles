# Git SSH authentication and signing

Git authentication and commit signing are SSH-first on every managed host. Home
Manager owns only public configuration and public signing keys. Private keys,
GitHub/GitLab tokens, agent state, and keychain entries remain mutable secrets
outside Git and the Nix store.

## Key policy and ownership

Use distinct keys for each machine or security boundary. A workstation key must
never be copied to a VPS, CI runner, recovery host, or another workstation.
Prefer a separate authentication key and signing key on each machine so either
capability can be revoked independently. A hardware-backed, 1Password, or
Bitwarden SSH agent may own the private material; Git still needs the matching
public signing key at `~/.ssh/id_ed25519_git_signing.pub`.

The repository owns:

- `home/git.nix`: Git and GitHub CLI policy;
- [`../home/git-allowed-signers`](../home/git-allowed-signers): reviewed public
  signing keys, with `alex@tyrode.dev` as the allowed principal; and
- the Home Manager link at `$XDG_CONFIG_HOME/git/allowed_signers`.

The operator owns private-key generation, agent/keychain availability, forge key
registration, and revocation. Public keys may be committed and enter the Nix
store; private keys and tokens must not.

## What “SSH-first” means

`gh repo clone` uses SSH because Home Manager sets `gh`'s `git_protocol` to
`ssh`. GitHub and GitLab HTTPS remotes also have `pushInsteadOf` rules, so a
manually added HTTPS remote keeps anonymous fetches over HTTPS but resolves its
push URL to SSH. This is deliberately not a blanket `insteadOf` rewrite: such a
rewrite would also redirect public scripts and `git+https` flake inputs through
SSH, breaking hosts without a loaded key.

Consequently, plain `git clone https://…` remains an HTTPS clone. Select the SSH
URL when cloning directly, and select GitLab's SSH URL until a managed GitLab CLI
exists. Check both stored and effective push URLs:

```sh
git remote -v
git remote get-url --push origin
gh config get git_protocol
```

An expected GitHub/GitLab push URL starts with `git@…` or `ssh://…`.

## Workstation bootstrap

Generate keys on the machine that will use them. The examples create ordinary
file-backed keys; when using a hardware or password-manager agent, use its key
creation flow and export only the public signing key to the configured `.pub`
path.

```sh
umask 077
ssh-keygen -t ed25519 -a 100 -C "alex@tyrode.dev (MACHINE git auth)" \
  -f ~/.ssh/id_ed25519_git_auth
ssh-keygen -t ed25519 -a 100 -C "alex@tyrode.dev (MACHINE git signing)" \
  -f ~/.ssh/id_ed25519_git_signing
chmod 600 ~/.ssh/id_ed25519_git_auth ~/.ssh/id_ed25519_git_signing
chmod 644 ~/.ssh/id_ed25519_git_auth.pub ~/.ssh/id_ed25519_git_signing.pub
```

Replace `MACHINE` with a stable, non-secret machine label. Register the
authentication public key with GitHub and GitLab. Register the signing public key
as an SSH signing key on each forge that supports it. GitHub treats
“authentication” and “signing” as separate registrations even when the same
public key is deliberately used for both roles.

Load private keys into the platform agent:

```sh
# Linux or another OpenSSH agent
ssh-add ~/.ssh/id_ed25519_git_auth
ssh-add ~/.ssh/id_ed25519_git_signing

# macOS system keychain
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_git_auth
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_git_signing
```

For a password-manager agent, enable its SSH-agent integration instead of
running `ssh-add` on a private file. Confirm `SSH_AUTH_SOCK` names a live socket
and `ssh-add -l` lists the machine's keys.

Before applying the configuration, add the new signing public key to
[`../home/git-allowed-signers`](../home/git-allowed-signers) in a reviewed PR:

```text
alex@tyrode.dev ssh-ed25519 <public-key-body>
```

Never paste a private key, token, credential-bearing URL, or `gh` hosts file into
the repository, issue, PR, build log, or Nix expression. Apply Home Manager only
after the public-key update is reviewed.

## Headless and VPS bootstrap

Generate a new authentication/signing pair on each headless host, or provision a
host-specific pair from an approved secret manager. Do not copy either private
key from a workstation or another server. A per-repository deploy key is
preferable when the host needs access to only one repository.

The login or service session must expose a supervised SSH-agent socket before
Git runs. Load only that host's keys. If the agent or key is absent, stop and
repair it; do not switch the remote to authenticated HTTPS and do not configure
`credential.helper=store`.

For unattended `gh` API use, prefer a short-lived `GH_TOKEN` injected into the
single process by the host's secret manager. `atyrode doctor git` reports such a
token as a warning because it can classify the process source but cannot verify
the external secret store. Persistent `gh auth login` on a server is acceptable
only when a working system keyring is present and `gh auth status` reports
`tokenSource` as `keyring`.

## GitHub CLI credential storage

Home Manager declares `programs.gh.gitCredentialHelper.enable`; this prevents
`gh auth setup-git` from imperatively editing managed Git configuration. The
helper itself stores no token: it delegates lookup to `gh`. It does **not** turn
a plaintext token already present in `gh/hosts.yml` into secure storage.

After login, classify storage without printing the token:

```sh
gh auth status --json hosts \
  --jq '[.hosts[][] | {host, login, tokenSource, state}]'
```

A durable login passes only when `tokenSource` is `keyring`. A filesystem path,
especially one ending in `gh/hosts.yml`, is the CLI's plaintext fallback: log
out immediately, repair the platform keyring, log in again, and re-check. Never
use `gh auth login --insecure-storage`. Environment token sources are suitable
only when the environment is populated by an approved external secret manager.

## Verification

Run the read-only aggregate diagnostic first:

```sh
atyrode doctor git
atyrode doctor git --json
```

It fails for an unavailable agent, no loaded key, an invalid or unsafe signing
public key, drifted `allowed_signers`, `credential.helper=store`, default
plaintext credential files, a missing declared `gh` helper, or known plaintext
`gh` token storage. It warns, without exposing URLs, when the current forge
remote can push over HTTPS without a recognized non-plaintext helper.

Then verify the actual transports and signing path:

```sh
ssh -T git@github.com
ssh -T git@gitlab.com
git fetch --dry-run
git push --dry-run
```

The forge SSH probes may return a non-zero status even when their message confirms
successful authentication. Read the message and confirm the expected account.
Use a disposable private repository to validate clone and a real no-op/test
branch push; a public repository cannot prove authenticated push behavior.

Verify signing in a disposable repository rather than adding a test commit to a
working branch:

```sh
test_repo="$(mktemp -d)"
git -C "$test_repo" init
git -C "$test_repo" commit --allow-empty -S -m "verify SSH signing"
git -C "$test_repo" log -1 --show-signature
```

The signature must identify `alex@tyrode.dev` through the managed
`allowed_signers` file.

## Planned rotation

1. Generate a new machine-specific key; keep the old private key in its current
   agent during the overlap.
2. Add the new public authentication/signing registrations to the forges.
3. Add the new public signing key to `home/git-allowed-signers`, review, apply,
   and confirm a new signed commit verifies.
4. Switch the agent and `user.signingKey` public file to the new key.
5. Remove the old authentication and signing registrations from every forge,
   unload the old private key, and remove its `allowed_signers` line in a second
   reviewed change.
6. Run `atyrode doctor git`, clone/fetch/push, and signed-commit verification on
   that machine.

Removing an old key from `allowed_signers` intentionally stops local trust in
its historical signatures. If historical trust must be retained with a bounded
validity window, design and review an OpenSSH `valid-before` policy before the
rotation; do not leave an obsolete key unbounded by accident.

## Emergency revocation

For a lost or compromised machine, do not use an overlap period:

1. Remove that machine's authentication and signing keys from GitHub, GitLab,
   deploy-key settings, and any other forge.
2. Remove the public key from `home/git-allowed-signers`, review, and apply the
   change on surviving hosts.
3. Unload the key from reachable agents and delete or revoke its private secret
   in the owning keychain/password manager.
4. Revoke any tokens or deploy credentials that were reachable from the lost
   machine. Remove plaintext fallback files only after the required credentials
   have been revoked or recovered elsewhere.
5. Bootstrap replacement keys as a new security boundary and re-run the full
   verification sequence.

## Recovery

If the private key still exists but the agent was restarted, restore the agent
socket and reload the machine's keys; never downgrade to plaintext HTTPS. If the
private key is gone, revoke its public registrations and generate a replacement
rather than copying a key from another host. If no trusted machine remains, use
the forge's account-recovery and 2FA process, revoke every lost machine key, and
bootstrap fresh per-machine keys before restoring repository access.

A retired host ID must not be reused for another security boundary. Keep public
key labels and forge registrations specific enough to identify exactly which
machine to revoke.
