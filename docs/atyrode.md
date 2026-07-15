# The `atyrode` CLI

`atyrode` is the shared, packaged interface for applying and inspecting these
dotfiles. It reads the declarative registry described in [Hosts and
capabilities](hosts.md); it does not infer a profile from the current directory
or maintain a second mutable profile database.

## Interactive cockpit

Running bare `atyrode` with both stdin and stdout attached to a terminal opens
the interactive cockpit. A bare non-TTY invocation continues to print CLI help,
and every explicit subcommand (`atyrode apply`, `atyrode doctor …`, JSON calls,
and the other command surfaces) continues through the Bash CLI even on a TTY.
Existing scripts therefore do not enter the cockpit.

The apply panel first resolves the requested branch to an exact commit, then
loads both `atyrode apply --ref <commit> --preview-json` and `atyrode inventory
--ref <commit> --json` asynchronously. Its default activation preview
summarizes package, store-path, and closure-size changes without showing raw
generation paths; `d` toggles normalized technical details, where the previous
and new generation paths remain available with labels.

Press `c` to open or focus the active capability inventory. `[`/`]` (or
left/right arrows) cycle in the apply plan's declared order, and `j`/`k` or
arrows scroll the focused pane. Wide terminals keep a 42-cell capability panel
beside the preview and use `Tab` to change focus; medium terminals use a
full-width capability view; narrow terminals stack the selection summary above
the scrollable details. `c` or `esc` returns to the preview without losing
selection or either scroll position.

Capability details are read only from the exact-revision CLI manifest. The
cockpit validates schema version, full revision, system/platform identity, and
the planned host's canonical id or alias before showing purpose, active state,
resolved deliverables, and ownership/security/mutable-state boundaries.
Loading and inventory failures remain textual and never block confirmation or
fall back to stale data.

Startup and refresh perform no activation. The operator must open the
confirmation step and accept it; the real apply uses that same exact commit, so
the activated configuration cannot drift from the preview if the branch
advances while the cockpit is open. The `ctrl+o` Ask overlay remains read-only
and preserves the full cockpit state.

## Applying a configuration

```sh
atyrode apply            # activate the latest published main; no checkout needed
atyrode apply --plan
atyrode apply --dry-run
atyrode apply --preview-json # stable schema for the read-only dry-run preview
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

After a successful activation, apply reports plain-omp settings that drifted
from the seeded repository defaults (see
[Agent tools](agent-tools.md#seeded-plain-omp-defaults)) and, when running on
a terminal without `--json`, offers a per-key keep-or-reset review. Drift is
never resolved automatically; skipping the review keeps every local value.

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
atyrode inventory --json
atyrode inventory --host alex-linux --json
atyrode inventory --ref <branch-tag-or-commit> --json
atyrode inventory --repo /absolute/path/to/checkout --json
atyrode doctor host --json
atyrode doctor system --json
atyrode doctor tools --json
```

`inventory` is a thin, read-only consumer of the flake's schema-versioned
evaluated manifest. By default it evaluates the exact immutable revision baked
into the installed CLI, so an older binary cannot accidentally describe its own
packages while targeting a newer revision. `--ref` selects a published target
revision and `--repo` selects a local checkout; they are mutually exclusive.
`--host` resolves canonical names and aliases inside that evaluated revision.
The command currently requires `--json`, returns compact key-sorted JSON, and
does not inspect closures, credentials, sessions, or other mutable state.

Diagnostics use stable non-zero exits for invalid input, missing files or tools,
identity mismatches, and activation failure. They do not expose credentials.
`doctor system [HOST] [--json]` audits the boundary that package installation
alone cannot satisfy: the real login shell, Nix daemon and trust policy,
container engine, antivirus ownership, Android device policy, and Homebrew
drift. Its stable check IDs, row schema, statuses, exits, and read-only probe
contract are documented in [Home Manager and system boundary](system-boundary.md).
The `workspace`, `agent`, `generations`, `rollback`, and `clean` namespaces are
reserved for their owning follow-up issues and currently fail clearly.
