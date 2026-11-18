---
name: git-hooks
description: "Contourner les hooks git est interdit : corrigez ce que le hook refuse. A refusing hook reports a defect; managed policy denies --no-verify, commit -n and core.hooksPath overrides"
scope: "tool:bash"
---

Contourner les hooks git est interdit : corrigez ce que le hook refuse.

A hook that refuses a commit or a push reports a defect the work still has.
Skipping it does not remove the defect; it moves the failure to CI, to a
reviewer or to main.

Managed policy denies, in `bash`:

- `--no-verify` on any git subcommand, and `git commit -n`;
- any `core.hooksPath` override: `git -c` / `--config-env`, `git config`, and
  the `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_PARAMETERS` environment.

A denial names the matching pattern (`Blocked by bash pattern: …`). Read the
hook's output, fix what it refuses, and commit again. If the hook itself is
wrong, say so and ask the operator; do not route around it through another tool
(`eval`, a script, editing `.git/config` or the hook file).
