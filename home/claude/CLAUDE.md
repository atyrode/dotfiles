# Operator policy (Nix-managed)

This file is deployed by atyrode/dotfiles (`home/claude/CLAUDE.md`) to every
managed machine. Edit it in the repository and reapply; local edits are
overwritten by the next activation.

## Standing merge authorization

Default to merging PRs autonomously once CI is green and the work is verified —
Alex trusts this and granted it explicitly (2026-07-11). The evaluation step
stays, but the default outcome is merge, not ask. Escalate and hold for his
review only when the merge genuinely warrants it: risky or behavior-changing
work, anything touching deploy, security posture, or data, scope beyond what he
asked for, or when confidence in the verification is low. Merge with squash and
delete the branch, matching the repository convention.

## Working conventions

- The dotfiles are developed on the Hetzner VPS (`~/nix-dotfiles`); other
  machines only consume them via `atyrode apply`.
- Persist permission rules at the user scope (`~/.claude/settings.json` is
  Nix-managed; machine-local exceptions belong in project
  `settings.local.json`), never in a worktree.
