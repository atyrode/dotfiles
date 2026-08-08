# ADR 0004: Agent trust tiers and restricted untrusted execution

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
normal managed environment: trusted-machine `yolo` approval with secret
obfuscation enabled. This supersedes issue #17's earlier recorded
`tools.approvalMode: write` default. Copy-on-write task isolation uses
policy-fixed automatic backend selection and patch merging when a spawn opts in;
it is not process or operating-system isolation. **Untrusted repositories run
through the dedicated restricted `ompu` launcher** with stripped credentials,
approval policy, and sanitized state. These controls reduce ambient authority;
they do not make a hostile repository contained or prevent an approved process
from exercising the launching user's authority.

The **managed configuration layer is immutable** for the paths that enforce this
posture (approvals, isolation, secrets) — a repository cannot edit its way out
of the policy, at rest or in a live session. Non-operator repository content is
treated as data to analyze, never as instructions to obey.

See [agent-security.md](../agent-security.md) and [agent-tools.md](../agent-tools.md).

## Consequences

- A hostile repository launched through `ompu` gets no inherited standing
  credentials and restricted tools, reducing its ambient authority. This is not
  hostile-code containment; approved processes still run with the launching
  user's operating-system authority.
- The trust decision is explicit (which tier a repository runs in), not implicit
  in whichever directory the agent happened to open.
- Because the enforcing config paths are Nix-owned and immutable, managed values
  survive machine-local or in-session configuration tampering.
- The restricted tier is a launch *mode*, not a per-repository profile to curate, which
  keeps the surface small (see ADR 0006).
