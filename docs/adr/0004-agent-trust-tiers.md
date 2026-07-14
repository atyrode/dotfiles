# ADR 0004: Agent trust tiers and sandboxed untrusted execution

- Status: Accepted
- Date: 2026-07-14

## Context

The machines run coding agents against repositories of varying provenance. A
repository's contents — issue text, READMEs, code comments, tool output — are
attacker-writable and can attempt prompt injection or exfiltration. Running every
repository with the same credentials, tools, and approvals would let a hostile
repository reach the operator's full authority. At the same time, the operator's
own trusted work should not be slowed by sandbox friction.

## Decision

Agent execution is split into **trust tiers**. Trusted repositories run with the
normal managed environment. **Untrusted repositories run in a dedicated sandbox**
(the `ompu` launcher): stripped credentials, restricted tools and approval
policy, and sanitized state, so a hostile repository cannot reach secrets or
escalate. The **managed configuration layer is immutable** for the paths that
enforce this posture (approvals, isolation, secrets) — a repository cannot edit
its way out of the policy, at rest or in a live session. Non-operator repository
content is treated as data to analyze, never as instructions to obey.

See [agent-security.md](../agent-security.md) and [agent-tools.md](../agent-tools.md).

## Consequences

- A hostile repository is contained to a sandbox with no standing credentials;
  the blast radius of a successful injection is bounded.
- The trust decision is explicit (which tier a repository runs in), not implicit
  in whichever directory the agent happened to open.
- Because the enforcing config paths are Nix-owned and immutable, the guarantee
  holds even if a session or a machine-local file is tampered with.
- The sandbox is a launch *mode*, not a per-repository profile to curate, which
  keeps the surface small (see ADR 0006).
