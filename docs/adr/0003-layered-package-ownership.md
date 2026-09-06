# ADR 0003: Layered package ownership

- Status: Accepted; amended 2026-09-06 (#586)
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
configurations. `modules/shared/capability-contract.nix` asserts that the
home a host evaluates to carries exactly the capabilities the registry
selected, and `checks/fleet/system-boundary.nix` asserts that a capability's
packages appear on every home selecting it and on no home without it.

*Amendment (2026-09-06).* The first implementation also generated a
narrative inventory: a versioned `inventory.<system>` flake output that
attributed every package to a capability by diffing baseline, `base`, and
`base + capability` evaluations, an annotations file recording each
capability's consumer and security boundary, an `atyrode inventory` verb,
and a document describing the manifest. Nothing consumed it but its own
checks and the cockpit that read it, so it was retired: the evaluated
configurations are the authority and the checks above read them directly.
The on-demand layer is `comma` from `base` (`, <attribute>`); the catalog of
reviewed entries that fronted it is a list in
[day-to-day.md](../day-to-day.md#occasional-tools).

## Consequences

- The presence of any package is explainable by its owning layer; there is no
  catch-all bucket.
- Capability packages compose with capability-based host composition (ADR 0001):
  turning a capability on brings its packages, off removes them.
- Evaluation checks reject capability drift between the registry and the
  evaluated home, and a capability package that leaks outside its capability.
- On-demand tools stay out of the installed closure, keeping machines lean while
  remaining one command away.
