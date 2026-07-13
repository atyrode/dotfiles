# omp-configured — the `code` launcher toolkit

`omp-configured` packages a curated set of [oh-my-pi](https://github.com/can1357/oh-my-pi)
(`omp`) coding-agent launchers, plus **`code`** — an `fzf` picker that browses them with a
live model-routing preview and a per-provider usage panel.

## What you get

- **`code`** — an interactive picker over the launcher palette (arrow keys / type to filter).
  The preview shows each profile's routing (`ctrl-f` cycles depth: lead → net → full chain),
  the bundled subagents, and a usage panel. Keyboard-driven (`--no-mouse`); `shift-↑/↓` or
  `alt-↑/↓` scroll the preview.
- **`omp`** — passthrough to your own **unmanaged** `~/.omp` config (the one mutable base).
- **`ompz / ompn / ompm / ompl / ompb / ompg / …`** — managed launchers, each pinning an
  opinionated routing profile (lane × tier) over `omp`. Their routing/policy is **immutable**
  (Nix-owned); only the bare `omp` is yours to edit freely.
- **`omph`** — prints the managed routing for every profile.
- **`ompu`** — a sandboxed launcher for untrusted repositories.

See [`../../omp/PROFILES.md`](../../omp/PROFILES.md) for the catalog and the reasoning behind
each profile.

## Install it standalone (Nix)

This package is a **flake output**, so it does **not** require the rest of these dotfiles. On
any machine that has Nix and uses `omp`:

```sh
nix profile install github:atyrode/dotfiles#omp-configured
```

That puts `code` and all the `ompX` launchers on your PATH. It's self-contained:

- The profile configs (`defaults.yml`, `presets/*.yml`, `policy.yml`) are **baked into the
  package** — the managed launchers layer them over your own `omp` automatically.
- Your bare `omp` keeps using your `~/.omp` config unchanged; the `ompX` profiles are just the
  suggestions layered on top.
- The usage panel prefers a private collector snapshot (`$TYRODE_MODEL_USAGE_SNAPSHOT`) and
  **falls back to `omp usage`** when it's absent, so it works anywhere.

## How the managed launchers stay reliable

Each `ompX` launcher runs `omp` with its profile config layered via `--config` at higher
precedence than your machine config, so ~47 managed paths (model roles, retry/fallback,
advisor, thinking level, approvals, isolation, …) always resolve to the profile's Nix-owned
values. Editing them in `~/.omp` — or in a running session — does **not** change the profile;
the overlay wins on every launch. To change a profile, edit the dotfiles and reapply; to
change the bare `omp`, edit `~/.omp`.

## In these dotfiles

Normally consumed via the Home-Manager module in
[`../../modules/home/agent-tools.nix`](../../modules/home/agent-tools.nix), which installs the
launchers and wires the supporting config. The standalone `nix profile install` path above is
for sharing the toolkit with others without adopting the whole dotfiles.

**Roadmap** (portability, provider-availability awareness, a usage/reset-aware profile
recommender, an HTML profiles wiki, advisor redesign): see the "code launcher roadmap" tracker
issue in the repo.
