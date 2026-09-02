---
name: parallel-write-isolation
description: "Prefer isolated: true when spawning multiple writing subagents — non-isolated writers share the live working tree"
scope: "tool:task"
---

Subagent isolation is per-spawn and optional (upstream contract): `isolated: true`
runs the agent in a copy-on-write workspace and returns its changes as a
reviewable patch; without it the agent edits the live working tree.

- Spawning **several writing agents concurrently**, or delegating a risky/large
  edit you may want to review before it lands → request `isolated: true`.
- Read-only work (scout research, reviews without edits) gains nothing from
  isolation — spawn it plain.
- Isolated agents are torn down at completion and cannot be revived for
  follow-up via `irc`; prefer non-isolated spawns when you expect a dialogue.

This is guidance, not enforcement: the operator can always demand isolation
explicitly, and merge behavior for isolated work is fixed by managed policy
(`patch`).
