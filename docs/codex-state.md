# Codex configuration and the defaults seed

Codex runs vanilla against `~/.codex`. The dotfiles no longer wrap it or manage
a profile layer: the former `codex-use` profile switcher and the
`--profile atyrode` launcher were retired. What the repository contributes now
is a **one-time config seed** plus a few **portable managed files** — everything
else in `~/.codex` is Codex-owned mutable state the dotfiles never touch.

## What the repository manages

| Path | Owner | Behavior |
|---|---|---|
| `~/.codex/config.toml` | seeded once, then user | On first activation the curated defaults (`codex/config.toml`) are installed. Any pre-existing file is timestamp-backed-up to `config.toml.pre-seed.<ts>` first (never merged). After that the file is yours — repository changes do not re-apply and your edits, including Codex's machine-local `[projects]` trust, are never touched again. |
| `~/.codex/AGENTS.md` | portable, repository-managed | Home Manager symlink to `codex/AGENTS.md` (global agent guidance). |
| `~/.codex/skills`, `~/.codex/templates` | portable, repository-managed | Home Manager recursive symlinks to `codex/skills` and `codex/templates`. |
| `auth.json` and provider credentials | secret, Codex-owned | Never read, copied into derivations, or moved. Log in with `codex login`. |
| history, sessions, rollouts, plugins, caches, logs, and `config.toml` after the seed | mutable, Codex-owned | Never entered into the Nix store or rewritten by the dotfiles. |

## The seed

`atyrode-codex-seed apply` (run automatically by Home Manager on activation, and
invokable by hand) performs the one-time install described above; it records a
marker under `$XDG_STATE_HOME/atyrode/codex-seed/` so it never runs twice.
`atyrode-codex-seed status [--json]` reports whether the seed has been applied.
A dry run (`AGENT_TOOLS_DRY_RUN=1`) writes nothing.

To re-apply the repository defaults after they change, remove the marker
(`rm ~/.local/state/atyrode/codex-seed/seeded`) and re-activate; your current
`config.toml` is backed up before the fresh install.

## Migrating from the old profile system

The retired `codex-use` kept multiple identities under `~/.codex-profiles/` and
swapped the active one into `~/.codex`. After the removal, `~/.codex` is just the
plain Codex home (your auth and data are already there). Home Manager clears the
two store symlinks the old converge left (`~/.codex/AGENTS.md`,
`~/.codex/atyrode.config.toml`) so the new managed files can take their place;
`~/.codex-profiles/` is left in place as harmless orphaned state you can delete.
See the [official configuration basics](https://learn.chatgpt.com/docs/config-file/config-basic#codex-configuration-file).
