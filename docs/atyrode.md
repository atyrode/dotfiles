# The `atyrode` CLI

`atyrode` is the shared, packaged interface for applying and inspecting these
dotfiles. It reads the declarative registry described in [Hosts and
capabilities](hosts.md); it does not infer a profile from the current directory
or maintain a second mutable profile database.

## Applying a configuration

```sh
atyrode apply            # activate the latest published main; no checkout needed
atyrode apply --plan
atyrode apply --dry-run
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

Linux uses `nh home switch`; macOS uses `nh darwin switch`. Plans name the
selected host and capabilities, installable, source, backend, revision,
dirty-tree state, and mutation boundary. Add `--json` for automation.
Activation shows a generation package diff.

`--restart-shell` only prints the explicit restart action after success. It
never replaces an embedded terminal. The historical `zconf` command is now a
thin wrapper around `atyrode apply`; it refreshes only Home Manager's realized
session variables and leaves full startup to `exec zsh -l` or a new terminal.

## Inspection and diagnostics

```sh
atyrode capabilities list --json
atyrode capabilities show alex-linux --json
atyrode doctor host --json
atyrode doctor tools --json
```

Diagnostics use stable non-zero exits for invalid input, missing files or tools,
identity mismatches, and activation failure. They do not expose credentials.
The `workspace`, `agent`, `generations`, `rollback`, and `clean` namespaces are
reserved for their owning follow-up issues and currently fail clearly.
