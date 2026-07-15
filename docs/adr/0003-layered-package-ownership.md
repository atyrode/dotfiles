# ADR 0003: Layered package ownership

- Status: Accepted
- Date: 2026-07-14

## Context

Packages arrive for different reasons and at different scopes: some belong on
every machine, some only where a capability is active, some are specific to one
host, and some are wanted only on demand for a single task. A single flat package
list cannot express *why* a package is present or *where* it should appear, and it
makes it impossible to check that a host has exactly what it should.

## Decision

Every package has **one owning layer**, and the layer determines its scope:

- **global** — on every managed machine;
- **capability** — present wherever a capability is active (e.g. `agent-tools`);
- **project / host** — specific to a host or project;
- **on-demand** — invoked transiently (e.g. via `nix run`), not installed.

Ownership is computed from the real evaluated Home Manager and nix-darwin
configurations. [`inventory/annotations.nix`](../../inventory/annotations.nix)
records only semantic intent and boundaries that evaluation cannot derive.

The versioned `inventory.<system>` flake output attributes packages by comparing
an identity-only baseline, `base`, and `base + capability` evaluations. It uses
the evaluated Darwin configuration for Homebrew casks. The same manifest powers
checks and the scriptable CLI; source parsing and committed package projections
are not authorities. Repository revision, system, platform, capability
composition, and host selection are part of the schema identity. Transitive
closures and secret-bearing mutable state are deliberately outside the default
manifest.

See [package-ownership.md](../package-ownership.md).

## Consequences

- The presence of any package is explainable by its owning layer; there is no
  catch-all bucket.
- Capability packages compose with capability-based host composition (ADR 0001):
  turning a capability on brings its packages, off removes them.
- An evaluation check rejects duplicate ownership, unknown annotations,
  incomplete host attribution, invalid platform conditionals, and composition
  drift.
- On-demand tools stay out of the installed closure, keeping machines lean while
  remaining one command away.
