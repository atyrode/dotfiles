# ADR 0002: Home Manager as primary authority; minimal system layer

- Status: Accepted
- Date: 2026-07-14

## Context

The configuration spans NixOS and macOS. macOS additionally has a system layer
(nix-darwin) and a large ecosystem of GUI applications that Nix cannot always
build or that ship as signed vendor bundles (Homebrew casks). A choice is forced:
how much lives at the system level versus the per-user Home Manager level, and
how are Homebrew-delivered apps kept declarative rather than hand-installed.

## Decision

**Home Manager is the primary authority** and owns the user environment on every
platform — packages, dotfiles, shell, and agent tooling. The **system layer is
kept minimal**: nix-darwin (and NixOS system config) own only what genuinely must
be system-level (OS defaults, daemons, users). **Homebrew casks converge
declaratively** — the set of casks is data the configuration owns and reconciles,
not an imperative `brew install` history.

See [system-boundary.md](../system-boundary.md).

## Consequences

- The same Home Manager modules and capability profiles work across Linux and
  macOS, so most configuration is written once (ADR 0001).
- macOS GUI apps that must come from Homebrew stay reproducible: the cask list is
  reviewed and converged, and drift (a manually installed cask) is visible.
- The system layer is small enough to reason about and re-create; it is not a
  second, competing place for user configuration.
- New machine setup is dominated by activating the Home Manager generation, not
  by system provisioning (see [bootstrap.md](../bootstrap.md)).
