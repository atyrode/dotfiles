---
name: update-check
description: Check in one read-only command whether OMP, Codex, the Manifold agent or the manifold-omp OMP SDK pin has a newer release than the operator's pins or this machine. Run at the start of substantial work, at most once per session.
---

# Update check

```console
$ bash ~/.agents/skills/update-check/check.sh
```

It compares the dotfiles `main` pins for OMP, Codex and the Manifold agent, and the `@oh-my-pi/*` SDK pin in atyrode/manifold-omp, with the latest published releases. It also checks that this machine runs the pinned OMP and Codex, and reports an open dotfiles pin-refresh PR. It changes nothing and takes a few seconds.

- `updates: nothing to do`: continue without mentioning it.
- A failure (offline, `gh` unauthenticated, an API error): continue without troubleshooting it.
- Any other output: one line per candidate. Ask the operator with the available question tool, quoting the lines, whether to act on them. Do not bump, merge or activate anything before the answer.

Each kind of line lands differently once the operator approves:

| Line | Route |
| --- | --- |
| `omp`, `codex` | In atyrode/dotfiles, dispatch the `update-pins` workflow or run `ci/update-pins.sh <name>`. The bot PR lands through its required checks. |
| `manifold-agent` | Hub first: follow `docs/manifold.md` "Upgrades" in atyrode/dotfiles. `update-pins` holds this bump until the hub serves the candidate's protocol. |
| `omp sdk` | In atyrode/manifold-omp, bump every `@oh-my-pi/*` dependency in `plugins/package.json` together. The `@oh-my-pi/pi-ai` patch is keyed by version. |
| `… on this machine …` | The machine is not running the generation dotfiles `main` pins. Activation is a separately authorized `atyrode apply`, never part of a bump. |
| `pending …` | A bump is already proposed. Report its merge state instead of opening another. |
