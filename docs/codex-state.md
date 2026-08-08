# Codex configuration and the defaults seed

Codex runs vanilla against `~/.codex`. The repository contributes a **one-time
config seed** plus a few **portable managed files**; everything else in
`~/.codex` is Codex-owned mutable state the dotfiles never touch.

## What the repository manages

| Path | Owner | Behavior |
|---|---|---|
| `~/.codex/config.toml` | seeded once, then user | On first activation the curated defaults (`codex/config.toml`) are installed. Any pre-existing file is timestamp-backed-up to `config.toml.pre-seed.<ts>` first (never merged). After that the file is yours — repository changes do not re-apply and your edits, including Codex's machine-local `[projects]` trust, are never touched again. |
| `~/.codex/AGENTS.md` | portable, repository-managed | Home Manager symlink to `codex/AGENTS.md` (global agent guidance). |
| `~/.codex/templates` | portable, repository-managed | Home Manager recursive symlink to `codex/templates`. |
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

See the [official configuration basics](https://learn.chatgpt.com/docs/config-file/config-basic#codex-configuration-file).
