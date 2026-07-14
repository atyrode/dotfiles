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

Ownership is recorded as data ([`inventory/packages.json`](../../inventory/packages.json))
and checked, so a package cannot silently appear at the wrong scope.

See [package-ownership.md](../package-ownership.md).

## Consequences

- The presence of any package is explainable by its owning layer; there is no
  catch-all bucket.
- Capability packages compose with capability-based host composition (ADR 0001):
  turning a capability on brings its packages, off removes them.
- A package-ownership check compares the declared inventory against what hosts
  actually install, so drift fails CI.
- On-demand tools stay out of the installed closure, keeping machines lean while
  remaining one command away.
