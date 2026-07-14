# Architecture decision records

ADRs record the **why** behind this repository's durable conventions and
boundaries — the choices that had meaningful alternatives or migration cost.
They are not a changelog (Git already preserves history) and not a how-to (the
topic docs under [`docs/`](../README.md) cover operation). An ADR is short: the
context that forced a choice, the decision, and its consequences.

Where truth lives, in order:

1. **Git configuration and Nix modules** state what the system should be.
2. **ADRs (here)** state why the conventions and boundaries exist.
3. **Topic docs** ([`docs/*.md`](../README.md)) state how each area works.
4. **Issues and PRs** record execution and evidence.

## When to write one

Write an ADR when a choice sets or moves a durable boundary — a new ownership
layer, a tool adopted or deliberately declined, a subsystem's model changing, or
a posture (like "not yet") worth recording so it is not re-litigated. Skip it for
routine fixes, mechanical refactors, or anything Git history already explains.

## Format

One file per decision: `docs/adr/NNNN-kebab-title.md`, numbered in order. Each
carries `Status` (Accepted / Proposed / Superseded), `Date`, an optional linked
decision issue, and `## Context` / `## Decision` / `## Consequences`. A superseded
ADR stays in place with a pointer to the one that replaced it. Numbering is local
to this repository.

## Records

| ADR | Decision |
| --- | --- |
| [0001](0001-capability-based-host-composition.md) | Capability-based host composition |
| [0002](0002-home-manager-primary-authority.md) | Home Manager as primary authority; minimal system layer |
| [0003](0003-layered-package-ownership.md) | Layered package ownership |
| [0004](0004-agent-trust-tiers.md) | Agent trust tiers and sandboxed untrusted execution |
| [0005](0005-no-declarative-secret-manager.md) | No declarative secret manager until a concrete secret needs it |
| [0006](0006-managed-layering-over-profiles.md) | Managed layering and seeding over curated profiles |
| [0007](0007-explicit-generation-cleanup.md) | Explicit, policy-driven generation and store cleanup |
