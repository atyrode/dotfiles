# ADR 0006: Managed layering and seeding over curated profiles

- Status: Accepted
- Date: 2026-07-14

## Context

Agent tools (OMP, Codex) can be configured two ways. One is a **curated matrix of
switchable profiles**: many hand-tuned named presets the operator picks between,
plus the machinery to switch, render, and browse them. The other is a **managed
base layer** the tool always runs under, with configuration either generated
on demand or seeded once. The repository originally built the first for both
tools — an OMP preset-launcher matrix with a browsable wiki, and a Codex
multi-profile switcher. In practice the switching was never used: a single
sensible default plus the ability to synthesize a profile covered every case, and
the curated matrices were pure maintenance burden and surface area.

## Decision

Deliver agent-tool configuration as an **immutable managed layer over the user's
mutable base**, plus a **generator or a one-time seed** — not a curated set of
switchable profiles.

- **OMP**: the `code` tool generates a profile from a prompt (or dials) and
  launches it through the zero-preset `omp-managed` layer; the hand-curated
  preset launchers and profiles wiki were removed (#151). This concerns *model
  routing*. Complete native profiles initially remained as the authentication
  boundary, but that also split sessions and settings. Issue #212 replaces
  runtime profile switching with isolated OMP v17 auth-broker vaults: credentials
  remain in their existing profile-local stores, while every trusted `code`
  client runs on shared profile `default`.
- **Codex**: runs vanilla against `~/.codex`; the curated defaults are a one-time
  seed into `config.toml` (then user-owned), and the multi-profile switcher was
  removed (#153).

See [agent-tools.md](../agent-tools.md) and [codex-state.md](../codex-state.md).

## Consequences

- Far less surface to maintain and test: one managed layer and one generator/seed
  per tool instead of a preset matrix and its switching, rendering, and browsing.
- The managed layer stays immutable where it enforces policy (ADR 0004); the
  configuration the operator actually edits is genuinely theirs (the seed applies
  once, then never overwrites).
- The model is uniform across tools — a plain CLI plus a managed layer — so there
  is one mental model rather than two bespoke profile systems.
- Curation moves from "pick a preset" to "generate what this task needs," which
  matches how the tools are actually used.
