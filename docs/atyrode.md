# The `atyrode` CLI

`atyrode` is the shared, packaged interface for applying and inspecting these
dotfiles. It reads the declarative registry described in [Hosts and
capabilities](hosts.md); it does not infer a profile from the current directory
or maintain a second mutable profile database.

## Applying a configuration

```sh
atyrode apply --plan
atyrode apply --dry-run
atyrode apply
```

The default host comes from `ATYRODE_HOST`, then the managed host identity file,
then an unambiguous user/system/hostname match. The checkout is the host's
declared `dotfilesDirectory`. Selecting either differently is intentional:

```sh
atyrode apply alex-x86_64-linux-desktop --repo /home/alex/nix-dotfiles --plan
```

Before calling `nh`, the CLI validates the host, user, system, checkout, Git
repository, backend, and revision. `--plan` performs no activation. `--dry-run`
uses `nh`'s build-only path. A successful real activation records the canonical
host atomically; failures and dry runs do not update state.

Linux uses `nh home switch`; macOS uses `nh darwin switch`. Plans name the
selected host and capabilities, installable, backend, revision, dirty-tree
state, and mutation boundary. Add `--json` for automation. Activation shows a
generation package diff.

`--restart-shell` only prints the explicit restart action after success. It
never replaces an embedded terminal. The historical `zconf` command is now a
thin wrapper around `atyrode apply`; it refreshes only Home Manager's realized
session variables and leaves full startup to `exec zsh -l` or a new terminal.

## Inspection and diagnostics

```sh
atyrode capabilities list --json
atyrode capabilities show alex-linux --json
atyrode doctor host --json
atyrode doctor system --json
atyrode doctor tools --json
```

Diagnostics use stable non-zero exits for invalid input, missing files or tools,
identity mismatches, and activation failure. They do not expose credentials.
`doctor system [HOST] [--json]` audits the boundary that package installation
alone cannot satisfy: the real login shell, Nix daemon and trust policy,
container engine, antivirus ownership, Android device policy, and Homebrew
drift. Its stable check IDs, row schema, statuses, exits, and read-only probe
contract are documented in [Home Manager and system boundary](system-boundary.md).
The `workspace`, `agent`, `generations`, `rollback`, and `clean` namespaces are
reserved for their owning follow-up issues and currently fail clearly.
