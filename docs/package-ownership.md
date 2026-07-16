# Package ownership

Installed membership is generated from evaluated configurations, not a package
matrix. `nix eval .#inventory.<system> --json` is the complete system manifest;
`nix eval .#capabilityInventory.<system>.<capability> --json` is its capability
projection. [`inventory/annotations.nix`](../inventory/annotations.nix) contains
only titles, purpose, demonstrated consumers, and state/security/delivery
boundaries. It intentionally contains no ordinary installed package or cask
arrays.

Each manifest is schema version 1 and identifies the exact flake revision,
system, and platform. Package and cask rows include deterministic name, version,
description, homepage, delivery, and source fields. Missing pinned metadata uses
an explicit deterministic fallback instead of live upstream lookup. Host rows
carry the selected capability composition and owner-attributed deliverables.
The evaluator rejects duplicate ownership, unknown semantic keys, unsupported
platform composition, and any evaluated top-level package or cask without an
owner. Home Manager's identity-only implementation support packages are the
baseline rather than user-facing deliverables.

The default inventory never traverses closures and never reads authentication,
sessions, caches, device identities, or other mutable state.

## Delivery layers

- `base` is the small operator/agent shell contract: Git/GitHub, search, JSON,
  direnv with nix-direnv, mise, diagnostics, `nh`, nix-index, and comma.
- `development` contains cross-repository Nix and shell quality tools. It does
  not provide application language versions.
- `agent-tools` owns Claude Code, Codex, OMP, their launch adapters,
  tmux, the Linux isolation backend, and the TUI-verification render stack
  (charm-freeze plus the JetBrains Mono and Nerd Font symbols render fonts,
  exposed through user fontconfig). Authentication, sessions, trust, and
  caches remain mutable and harness-owned outside derivations.
- `desktop`, `mobile`, `media`, `containers`, and `security` are explicit host
  capabilities. Container daemons and Homebrew application state remain
  system-owned. The `security` capability contains network diagnostics; ClamAV
  is intentionally unowned because there is no signature-update and scanning
  workflow.
- Python/Pillow/uv, Node/Bun/Deno, Go, Rust, and GCC are project-owned. A Nix
  project commits a dev shell and `.envrc`; other projects commit `mise.toml`
  plus their native manifest. Nix and mise must not own the same project runtime.
- Infrequent commands use comma or an explicit `nix shell`; diagnostics direct
  missing tools back to the owning capability instead of suggesting a global
  install.

Desktop applications are retained as an operator-use decision, separate from
the agent platform. Pi and Zed remain absent, coherent experiments owned by #29
and #30; neither is pulled into the baseline for harness symmetry.

Vendor-signed macOS application bundles must retain their upstream signing
identity; package fixup must not replace a Developer ID signature with an ad-hoc
one. The Darwin package overlay disables fixup for Spotify specifically so its
`com.spotify.client` / `2FNC3A47ZF` identity survives Home Manager delivery.
The full application audit and any other package decisions remain tracked by #89.

## Harness and surface contract

| Harness/surface | Hosts | Version owner | Mutable state | Supported launch modes |
|---|---|---|---|---|
| Claude Code CLI | `agent-tools` | pinned nixpkgs | `~/.claude`, `~/.claude.json` | interactive, print |
| Codex CLI | `agent-tools` | pinned upstream release binaries (repository derivation) | `~/.codex` | interactive, exec |
| OMP | `agent-tools` | repository derivation | profile-scoped auth, sessions, MCP, caches | normal, generated, untrusted, ACP |
| tmux adapter | `agent-tools` | pinned nixpkgs | tmux server sockets and sessions | interactive |
| bubblewrap backend | Linux `agent-tools` | pinned nixpkgs | none | OMP task isolation |
| comma + nix-index | `base` | pinned flake input | immutable index/shared store | lookup, on-demand command |
| Pi/extensions | none pending #29 | unassigned | must be isolated | evaluation only |
| Zed/ACP surface | none pending #30 | unassigned | editor-owned | evaluation only |

`atyrode doctor tools --json` reports these versions, launch modes, paths,
owners, and missing-capability remediation without reading authentication state.
Package presence is separate from system readiness. `atyrode doctor system
[HOST] [--json]` verifies the system-owned login shell, daemon policy,
container engine, Android access policy, antivirus disposition, and Homebrew
drift without changing them. See [Home Manager and system
boundary](system-boundary.md).

## Closure review

The default inventory excludes transitive closures. Exact sizes vary by platform
and nixpkgs revision and remain an explicit diagnostic. Measure a pinned
workstation closure without activating it, and build the portable server
manifest for its separately enforced budget:

```sh
nix build --no-link .#homeConfigurations.alex-x86_64-linux.activationPackage
nix path-info -Sh .#homeConfigurations.alex-x86_64-linux.activationPackage

nix build .#server-profile-manifest
jq . result/manifest.json
```

Use the same commands for each canonical host before accepting a large package
or capability. The shared Nix store deduplicates identical dependencies across
hosts and workspaces; a binary cache can be added without changing ownership.

At the pinned 2026-07-08 nixpkgs revision, the portable x86_64-linux server
profile delivers 41 top-level packages and measures 2,430,232,848 NAR bytes
across 409 store paths. Its enforced ceilings are 45 packages, 2,617,245,696
bytes, and 450 paths. The profile deliberately excludes development, containers, security,
media, mobile, and desktop capabilities; it therefore contains neither
workstation language stacks, container clients, nor antivirus software. The
aarch64 ceilings are 45
packages, 2.5 GiB, and 500 paths and are enforced by the native CI runner. See
[Portable Home Manager profiles](portable-profiles.md) for the manifest schema
and pin/update workflow.
