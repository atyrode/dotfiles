# ADR 0007: Explicit, policy-driven generation and store cleanup

- Status: Accepted
- Date: 2026-07-14
- Decision issue: `atyrode/dotfiles#21`

## Context

Home Manager generations, profile generations, build results, and GC roots
accumulate independently, and garbage collection only frees paths once obsolete
roots and generations are removed. Cleanup therefore needs a retention policy and
safeguards. The tempting shortcuts are dangerous: garbage-collecting on every
activation can wipe the rollback window a user depends on; raw
`nix-collect-garbage` has no policy or protection; and granting broad
trusted-user GC privileges widens the trust surface for a routine chore.

## Decision

Cleanup is **explicit and policy-driven**:

- **`nh` is the human-facing backend** for generation inspection, diffs,
  rollback, and cleanup; native `nix` commands are a fallback only for a tested
  platform gap.
- **`atyrode` owns the retention policy and safeguards**: it always keeps the
  current generation and a rollback window, which are provably not selectable for
  deletion.
- **Cleanup never runs as a side effect of `atyrode apply`** — it is a separate,
  dry-run-and-confirmation command.

The verbs and their flags are `atyrode --help`; the rollback story is in
[day-to-day.md](../day-to-day.md#keeping-the-machine-small).

## Consequences

- `atyrode clean` cannot delete the current generation or the configured rollback
  set; a test enforces this so the safety net cannot regress.
- Activation never surprises the operator by reclaiming disk; disk pressure is
  surfaced by diagnostics, not resolved by silent deletion.
- `atyrode clean` is `nh clean` for the profiles this machine's activation
  owns, with the retention window as arguments: nh removes the generations and
  the GC roots that pinned them and collects the store, and nh's own plan and
  confirmation are the preview. The cleanup nh cannot know about — stale macOS
  app aliases a dropped package leaves behind — is the only work atyrode adds.
