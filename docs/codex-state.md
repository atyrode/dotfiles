# Codex configuration and profile state

Codex reads mutable user configuration from `~/.codex/config.toml` and supports
an explicit profile layer at `$CODEX_HOME/<name>.config.toml`. The managed
launcher uses the documented `--profile atyrode` layer so portable defaults can
converge without replacing user/project trust entries in the base file. See the
official [configuration basics](https://learn.chatgpt.com/docs/config-file/config-basic#codex-configuration-file)
and [developer command reference](https://learn.chatgpt.com/docs/developer-commands).
Machine-local keys remain in the base file; the managed layer intentionally wins
when both layers define the same portable default.

## Ownership

| Path | Owner | Behavior |
|---|---|---|
| `AGENTS.md` | portable, repository-managed | Convergent symlink; pre-existing content is timestamp-backed up first. |
| `atyrode.config.toml` | portable, repository-managed | Convergent Codex profile layer selected by the packaged launcher. |
| `config.toml` and named non-atyrode profiles | machine-local/user | Never replaced; project trust and personal overrides stay local. |
| `auth.json` and provider credentials | secret, Codex-owned | Never read by diagnostics, copied into derivations, or moved outside its auth profile. |
| history, sessions, rollouts, plugins, skills config, caches, logs | mutable, Codex-owned | Move with the selected authentication profile; never enter the Nix store. |

The CLI and managed profile contain no credentials. `codex-use status --json`
reports only the active profile and this ownership classification.

## Commands

```sh
codex-use status --json
codex-use list
codex-use alt
codex-use login alt
codex-use path alt
codex-use migrate
```

`main` remains a compatibility spelling for `default`. `codex-use login`
selects the profile transactionally, then starts device authentication. The
separate shell-only login wrappers were removed by #12.

Every mutating invocation takes an atomic per-user directory lock. A switch
preflights process and destination collisions, installs managed files before
moving directories, records a recovery journal, moves the active and inactive
profiles, then atomically writes `.active-profile`. The next invocation rolls
back an interrupted partial move or completes a layout that had already
finished. Managed-path collisions are preserved under a timestamped
`.pre-managed.*` name rather than deleted.

Home Manager runs `codex-use converge` on every switch. It updates only the two
portable files in the active and inactive profiles. Existing seeded profiles
therefore converge without a manual sync and without changing `config.toml`,
authentication, history, sessions, plugin state, or caches.
