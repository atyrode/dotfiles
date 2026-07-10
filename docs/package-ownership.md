# Package ownership

The checked source of truth is [`inventory/packages.json`](../inventory/packages.json).
Every package has one delivery owner, a demonstrated consumer, a version owner,
a mutable-state boundary, and a coarse closure class. The flake rejects duplicate
entries and rejects workstation runtimes, mobile/media tools, and GUI packages
from the server composition.

## Delivery layers

- `base` is the small operator/agent shell contract: Git/GitHub, search, JSON,
  direnv with nix-direnv, mise, diagnostics, `nh`, nix-index, and comma.
- `development` contains cross-repository Nix and shell quality tools. It does
  not provide application language versions.
- `agent-tools` owns Codex, OMP, Herdr, their launch adapters, tmux, and the
  Linux isolation backend. Authentication, sessions, trust, and caches remain
  mutable and harness-owned outside derivations.
- `desktop`, `mobile`, `media`, `containers`, and `security` are explicit host
  capabilities. Container daemons and Homebrew application state remain
  system-owned.
- Python/Pillow/uv, Node/Bun/Deno, Go, Rust, and GCC are project-owned. A Nix
  project commits a dev shell and `.envrc`; other projects commit `mise.toml`
  plus their native manifest. Nix and mise must not own the same project runtime.
- Infrequent commands use comma or an explicit `nix shell`; diagnostics direct
  missing tools back to the owning capability instead of suggesting a global
  install.

Desktop applications are retained as an operator-use decision, separate from
the agent platform. Pi and Zed remain absent, coherent experiments owned by #29
and #30; neither is pulled into the baseline for harness symmetry.

## Harness and surface contract

| Harness/surface | Hosts | Version owner | Mutable state | Supported launch modes |
|---|---|---|---|---|
| Codex CLI | `agent-tools` | pinned nixpkgs | `~/.codex`, isolated profiles | interactive, exec |
| OMP | `agent-tools` | repository derivation | profile-scoped auth, sessions, MCP, caches | normal, preset, untrusted, ACP |
| Herdr + tmux adapter | `agent-tools` | repository derivation + pinned nixpkgs | workspace registry and tmux server | workspace, agent |
| bubblewrap backend | Linux `agent-tools` | pinned nixpkgs | none | OMP task isolation |
| comma + nix-index | `base` | pinned flake input | immutable index/shared store | lookup, on-demand command |
| Pi/extensions | none pending #29 | unassigned | must be isolated | evaluation only |
| Zed/ACP surface | none pending #30 | unassigned | editor-owned | evaluation only |

`atyrode doctor tools --json` reports these versions, launch modes, paths,
owners, and missing-capability remediation without reading authentication state.

## Closure review

The matrix records a stable coarse contribution so large additions are visible
in review. Exact sizes vary by platform and nixpkgs revision. Measure the pinned
host closure without activating it:

```sh
nix build --no-link .#homeConfigurations.alex-x86_64-linux.activationPackage
nix path-info -Sh .#homeConfigurations.alex-x86_64-linux.activationPackage

nix build --no-link '.#homeConfigurations.alex@ubuntu-4gb-nbg1-1.activationPackage'
nix path-info -Sh '.#homeConfigurations.alex@ubuntu-4gb-nbg1-1.activationPackage'
```

Use the same commands for each canonical host before accepting a large package
or capability. The shared Nix store deduplicates identical dependencies across
hosts and workspaces; a binary cache can be added without changing ownership.

At the pinned 2026-07-10 revision, realized x86_64-linux closures measure 2.5
GiB for `alex-x86_64-linux` and 3.1 GiB for the server composition. The server
delta is the declared `containers` and `security` capabilities, chiefly Docker
clients and ClamAV—not workstation language stacks or desktop software. Darwin
and aarch64 sizes must be measured on compatible builders; CI evaluates those
compositions structurally on every change.
