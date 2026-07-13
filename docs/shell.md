# Shell surface

The interactive shell is a thin launcher, not a development environment.
Home Manager owns completion, fzf, zoxide, direnv/nix-direnv, mise, and the
single retained Oh My Zsh `git` plugin. Projects own language environments.

## Disposition inventory

| Surface | Disposition | Evidence or replacement |
|---|---|---|
| `ls=tree -L 1` | removed | Changed standard command semantics for people, copied instructions, and agents; use `tree -L 1` explicitly. |
| `cl=clear`, `htop=btop` | removed | Muscle-memory aliases provided no policy and shadowed common command names. |
| handwritten fzf/zoxide `eval` | Home Manager | `programs.fzf` and `programs.zoxide` generate supported Zsh integration. |
| automatic fastfetch | removed side effect | Run `fastfetch` explicitly; startup no longer launches a subprocess or prints cosmetic output. |
| `atmux` | removed | It only wrapped `tmux attach-session -t`; use tmux directly for persistent agent workspaces. |
| Codex login/profile wrappers | removed | Use `codex-use <profile>` or the transactional `codex-use login <profile>` command. |
| color helpers | removed | Their source-parsing help/activation consumers were removed by #7. |
| `atyrode()` source parser | removed by #7 | Packaged `atyrode capabilities` and `atyrode doctor` commands. |
| large `zconf` workflow | replaced by #7 | `atyrode apply`; a thin `zconf` compatibility function remains until 2026-10-01. |
| Python/venv helpers | removed by #20 | Project dev shell, `mise.toml`, or native manifest. |
| `local.zsh` | retained, narrow | Interactive machine-local behavior only; no portable project, runtime, credential, or shared tool policy. |
| `COLORTERM` derivation | added | sshd's default `AcceptEnv` drops Ghostty's forwarded `COLORTERM`; `colorterm.zsh` restates `truecolor` when `TERM=xterm-ghostty` and never overrides an existing value. |
| Oh My Zsh `git` | retained | Transparent Git aliases/completion used by the interactive shell. |
| Oh My Zsh tmux/docker plugins | removed | Explicit container capabilities own those workflows; plugins were loaded on unrelated hosts. |

No compatibility alias shadows a common command. `zconf` is the only temporary
compatibility surface and has a recorded removal date.

## Startup behavior and measurement

The checked smoke test proves that non-interactive shells do not load
`local.zsh`, interactive shells do, fastfetch is not executed, removed aliases
and functions are unavailable, completion remains enabled, fzf, zoxide,
and nix-direnv are Home Manager-owned, and `COLORTERM` is derived only for
`xterm-ghostty` sessions that arrive without one.

On 2026-07-10, ten clean source-tree interactive runs measured with Hyperfine
before this refactor averaged **26.9 ms ± 2.6 ms**. The equivalent command after
the refactor averaged **4.0 ms ± 2.1 ms** (one high outlier; 3.1 ms minimum).
Reproduce it without activating a generation:

```sh
nix shell nixpkgs#hyperfine -c hyperfine --warmup 2 --runs 10 --shell=none \
  "zsh -dfi -c 'source home/shell/nix.zsh; source home/shell/startup.zsh'"
```
