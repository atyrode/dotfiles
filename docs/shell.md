# Shell surface

The interactive shell is a thin launcher, not a development environment.
Home Manager owns completion, fzf, zoxide, direnv/nix-direnv, mise, and the
single retained Oh My Zsh `git` plugin. Projects own language environments.

## Current surface

- Home Manager owns completion, fzf, zoxide, direnv/nix-direnv, mise, and the
  Oh My Zsh `git` plugin.
- `home/shell/startup.zsh` loads only the machine-local
  `~/.config/zsh/local.zsh` hook, and only in an interactive shell.
- `home/shell/cwd.zsh` emits OSC 7 working-directory metadata at each prompt
  so Rio's file-path hints resolve relative paths from the authoritative shell.
- `home/zsh.nix` sources `fzf --zsh` only with a TTY. Home Manager's generated
  hook remains disabled until its option restore no longer prints
  `can't change option: zle` in TTY-less interactive shells (#255).
- Projects own language runtimes and development environments through dev
  shells, `mise.toml`, or native manifests.

## Verification

`checks/shell-surface.nix` proves that non-interactive shells do not load the
local hook, interactive shells do, shell startup does not execute `fastfetch`,
completion remains enabled, fzf/zoxide/nix-direnv remain Home Manager-owned,
and OSC 7 metadata encodes paths safely.
