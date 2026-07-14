# omp-configured — the `code` profile generator

`omp-configured` packages [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`), the
coding-agent launcher, plus **`code`** — an interactive TUI that builds an OMP routing
profile from a prompt (or a few dials) and launches it, with a per-provider usage panel.

## What you get

- **`code`** — the profile generator (Bubble Tea TUI). Type a prompt and/or adjust the
  facet dials (lane, model tier, thinking, spark, fable); a local prompt→profile classifier
  (running on the resident ollama daemon) suggests settings. **Enter** launches:
  - with nothing changed → your **default `omp`** ("run my normal omp");
  - after a prompt or a dial change → the **generated** profile, layered over the managed
    defaults and policy.

  Press **`u`** to open the untrusted sandbox for the current directory, `?` for all keys.
- **`omp`** — passthrough to your own **unmanaged** `~/.omp` config (the one mutable base;
  `omp update` is blocked since the package is Nix-managed).
- **`omp-managed`** — the managed-layering primitive: platform extensions + managed defaults
  + policy applied to a one-shot `--config`. This is the launch target `code` uses for a
  generated profile; it is also useful directly.
- **`ompu`** — a sandboxed launcher for untrusted repositories (stripped credentials,
  restricted tools/approvals, sanitized state).

The generator's model catalog and cost figures live in
[`../../omp/models.yml`](../../omp/models.yml) (synced from `omp models`).

## Install it standalone (Nix)

This package is a **flake output**, so it does **not** require the rest of these dotfiles. On
any machine that has Nix and uses `omp`:

```sh
nix profile install github:atyrode/dotfiles#omp-configured
```

That puts `code`, `omp`, `omp-managed`, and `ompu` on your PATH. It's self-contained:

- The managed config (`defaults.yml`, `policy.yml`, `untrusted.yml`) and the generated
  routing grid are **baked into the package**.
- Your bare `omp` keeps using your `~/.omp` config unchanged.
- The usage panel prefers a private collector snapshot (`$TYRODE_MODEL_USAGE_SNAPSHOT`) and
  **falls back to `omp usage`** when it's absent, so it works anywhere.

## How the managed layering stays reliable

`omp-managed` (and the generated profiles launched through it) run `omp` with the managed
config layered via `--config` at higher precedence than your machine config, so the managed
paths (model roles, retry/fallback, advisor, thinking level, approvals, isolation, …) always
resolve to their Nix-owned values. Editing them in `~/.omp` — or in a running session — does
**not** change them; the overlay wins on every launch. To change the managed base, edit the
dotfiles and reapply; to change the bare `omp`, edit `~/.omp`.

## In these dotfiles

Normally consumed via the Home-Manager module in
[`../../modules/home/agent-tools.nix`](../../modules/home/agent-tools.nix), which installs the
launchers and wires the supporting config. The standalone `nix profile install` path above is
for sharing the toolkit with others without adopting the whole dotfiles.
