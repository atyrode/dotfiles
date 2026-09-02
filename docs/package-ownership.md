# Package ownership

Installed membership is generated from evaluated configurations, not a package
matrix. `nix eval .#inventory.<system> --json` is the complete system manifest;
`nix eval .#capabilityInventory.<system>.<capability> --json` is its capability
projection. [`inventory/annotations.nix`](../inventory/annotations.nix) contains
only titles, purpose, demonstrated consumers, and state/security/delivery
boundaries. It intentionally contains no ordinary installed package or cask
arrays.

Decision record: [ADR-0003](adr/0003-layered-package-ownership.md).

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
- `development` contains cross-repository Nix, shell, and workflow quality
  tools. It does not provide application language versions.
- `agent-tools` owns Claude Code, Codex, OMP, their launch adapters, Node and
  Bun runtime support for agent workflows, tmux, the Linux isolation backend,
  and the TUI-verification render stack (charm-freeze plus the JetBrains Mono
  and Nerd Font symbols render fonts, exposed through user fontconfig).
  Authentication, sessions, trust, and
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


### Native Windows package policy

Native Windows has a separate, directly reviewed package declaration in
[`windows/packages.nix`](../windows/packages.nix). It is exported as
`lib.windowsPackages` and consumed by the WSL-side `atyrode windows` controller;
it is intentionally not folded into Nix's evaluated package/cask inventory.
The inventory carries a single source kind. `winget` packages (Zen Browser
Twilight and JetBrainsMono Nerd Font) are install-only and exact-ID based:
WinGet owns installation and each package's normal update channel. An installed
stable Zen package blocks Twilight installation with an explicit profile-backup
and manual-uninstall remediation instead of deleting operator state; the font
has no conflicting package and supplies the Nerd glyph family the operator's
terminal UIs need. Nix owns the NixOS-WSL control plane that invokes
reconciliation, not the resulting Windows package or a fictional
cross-platform generation. Browser accounts, profiles, cookies,
sessions, update services, and caches remain Zen/Windows-owned and are never
copied into a derivation.

### macOS application-signing policy

Vendor-signed macOS application bundles delivered by Nix and Home Manager must
retain their upstream Developer ID identity. Darwin fixup must not replace that
identity with an ad-hoc signature. A package-specific
`overrideAttrs (_: { dontFixup = true; })` is allowed only after the exact
artifact selected by the locked derivation has a verified Developer ID
signature and the derivation copies the app bundle without modifying its sealed
contents. Each such override must have a native Darwin regression check for the
main executable's CodeDirectory identifier and team ID and for the
`Info.plist` bundle ID. Do not disable fixup globally.

An application built from source, or an upstream bundle whose sealed contents
must be patched or wrapped in place, has no preservable vendor identity and may
remain ad-hoc signed when the rationale is recorded. A repository-generated web
launcher is a separate local-wrapper class and must not claim a vendor identity.

The table covers every Nix/Home Manager app bundle selected by
[`home/profiles/desktop.nix`](../home/profiles/desktop.nix), plus the current
OrbStack bundle from the `containers` capability. Nix-darwin/Homebrew casks are
system-owned, never pass through Nix's Darwin fixup or Home Manager `copyApps`,
and are therefore outside this Nix-bundle table.

| Application (package) | Classification and expected identity | Evidence and rationale |
|---|---|---|
| ChatGPT (`chatgpt`) | Vendor-signed preserved: `com.openai.chat` / `2DC432GLL2` | #89 observed the identity in the delivered bundle; the locked derivation copies the official `ChatGPT.app` under `stdenvNoCC`. |
| Obsidian (`obsidian`) | Vendor-signed preserved: `md.obsidian` / `6JSW4SJWN9` | The locked `Obsidian-1.12.7.dmg` is `sha256-O4XBO0zlVRLobhcKfNKklOLbaVrIiMBgHhU8uFt3iBs=`. `rcodesign` reports a verifying Developer ID Application chain for Dynalist Inc. on both executable slices. The derivation copies `Obsidian.app` unchanged and creates wrappers outside it; the overlay skips destructive fixup and [`app-signatures`](../checks/app-signatures.nix) enforces the identity. |
| Postman (`postman`) | Vendor-signed preserved: `com.postmanlabs.mac` / `H7H8Q7M5CK` | #89 observed the identity; the locked Darwin derivation already sets `dontFixup = true` because changing embedded scripts invalidates notarization. |
| Prism Launcher (`prismlauncher`) | Intentionally source-built/ad-hoc: bundle `org.prismlauncher.PrismLauncher`, no team ID | `prismlauncher-unwrapped` fetches source tag `11.0.3`, applies a Nix-specific patch and branding, builds with CMake, and its launcher is then Qt-wrapped. No upstream vendor signature can survive that build. |
| REAPER (`reaper`) | Vendor-signed preserved: `com.cockos.reaper` / `Y3T58622SG` | #89 observed the identity; the locked derivation copies the official universal DMG bundle and disables stripping. |
| Signal (Homebrew cask `signal`) | System-owned cask, vendor-signed: `org.whispersystems.signal-desktop` / Signal Messenger team ID | Moved out of Nix: nixpkgs has no cached aarch64-darwin build, so the package was a multi-hour Electron compile on every fresh machine and every CI run, producing an ad-hoc-signed bundle. The cask is the vendor release. Listed here so the move is recorded; casks are otherwise outside this table. |
| Spotify (`spotify`) | Vendor-signed preserved: `com.spotify.client` / `2FNC3A47ZF` | The exact-artifact audit and native built-bundle proof landed in [#242](https://github.com/atyrode/dotfiles/pull/242); [`app-signatures`](../checks/app-signatures.nix) enforces the identity. |
| VLC (`vlc-bin`) | Vendor-signed preserved: `org.videolan.vlc` / `75GAHG3SZQ` | The locked `vlc-3.0.23-arm64.dmg` is `sha256-/G+sCNh/U4UX1ErKDF56JEtnyMTLWJv0eDY6cxX9Xg0=`. `rcodesign` reports a verifying Developer ID Application chain for VideoLAN. The derivation copies `VLC.app` unchanged and creates its wrapper outside it; the overlay skips destructive fixup and [`app-signatures`](../checks/app-signatures.nix) enforces the identity. |
| Lichess (`lichess`) | Local web-app wrapper: `org.lichess.webapp`, no vendor team ID | [`home/desktop/lichess.nix`](../home/desktop/lichess.nix) generates the bundle, plist, and shell launcher locally; it only opens `https://lichess.org`. |
| OrbStack (`orbstack`, `containers`) | Vendor-signed preserved: `dev.kdrag0n.MacVirt` / `HUAQ24HBR6` | #89 observed the identity in the delivered bundle; this app belongs to the `containers` capability rather than the desktop profile. |

## Harness and surface contract

| Harness/surface | Hosts | Version owner | Mutable state | Supported launch modes |
|---|---|---|---|---|
| Claude Code CLI | `agent-tools` | pinned nixpkgs | `~/.claude`, `~/.claude.json` | interactive, print |
| Codex CLI | `agent-tools` | pinned upstream release binaries (repository derivation) | `~/.codex` | interactive, exec |
| OMP | `agent-tools` | repository derivation | profile-scoped auth, sessions, MCP, caches | normal, generated, untrusted, ACP |
| tmux adapter | `agent-tools` | pinned nixpkgs | tmux server sockets and sessions | interactive |
| bubblewrap backend | Linux `agent-tools` | pinned nixpkgs | none | OMP task isolation |
| comma + nix-index | `base` | pinned flake input | immutable index/shared store | lookup, on-demand command |

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

At the current pinned nixpkgs revision, the portable x86_64-linux server
profile delivers 66 top-level packages and measures 4,221,748,400 NAR bytes
across 774 store paths. Its enforced ceilings are 72 packages, 5 GiB, and 850
paths. The profile deliberately excludes development, containers, media,
mobile, and desktop capabilities; it includes the shared security diagnostics
but no antivirus software. The aarch64 ceilings are likewise 72 packages,
5 GiB, and 850 paths and are enforced by the native CI runner. See
[Portable Home Manager profiles](portable-profiles.md) for the manifest schema
and pin/update workflow.
