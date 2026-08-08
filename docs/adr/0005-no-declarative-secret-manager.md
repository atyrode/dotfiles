# ADR 0005: No declarative secret manager until a concrete secret needs it

- Status: Accepted
- Date: 2026-07-14

## Context

Mature Nix dotfiles frequently adopt a declarative secret manager (agenix,
sops-nix). It is tempting to add one for completeness. But a secret manager earns
its complexity only when the repository must *deliver* a secret declaratively —
an encrypted payload that Nix decrypts into a known path at activation. This
repository currently has no such payload: agent credentials are owned by their
tools (`~/.omp`, `~/.codex`) and never enter the Nix store, and the remaining
secret-adjacent concern is Git credentials and commit signing.

## Decision

**Do not adopt agenix, sops-nix, or an equivalent yet.** Adding one now would be
machinery without a payload to justify it. Instead: record the classes of secrets
in play and their current owners, keep tool-owned credentials out of the store,
and revisit a secret manager only when a concrete secret must be delivered
declaratively. Git credential and signing bootstrap is tracked separately in #8.

See [agent-security.md](../agent-security.md).

## Consequences

- No encryption tooling, key distribution, or `.age`/`.sops` files to maintain
  until there is something for them to carry.
- Tool credentials stay owned by the tools that created them; the configuration
  never reads or copies them, which keeps them out of derivations and logs.
- The trigger to revisit is explicit — "a concrete secret needs declarative
  delivery" — so this is a recorded posture, not an oversight to be re-argued.
- If that trigger arrives, this ADR is superseded by one that picks a tool
  against the actual payload's threat model.
