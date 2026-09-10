# omp-configured — managed and untrusted OMP launchers

`omp-configured` packages [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`)
with declarative launch policy. [Code](https://github.com/atyrode/code) is a
separate native Manifold plugin family, not a command shipped by this package.

## What you get

- **`omp`** — passthrough to your own **unmanaged** `~/.omp` config (the one mutable base;
  `omp update` is blocked since the package is Nix-managed).
- **`omp-managed`** — platform extensions, managed defaults and policy applied
  through a one-shot `--config`, without replacing the operator's configuration.
- **`ompu`** — a sandboxed launcher for untrusted repositories (stripped credentials,
  restricted tools/approvals, sanitized state).

Use the pinned binary's `omp --help` and `omp <command> --help` for upstream
behavior; this README describes the three repository launchers.

## Install it standalone (Nix)

This package is a **flake output**, so it does **not** require the rest of these dotfiles. On
any machine that has Nix and uses `omp`:

```sh
nix profile install github:atyrode/dotfiles#omp-configured
```

That puts `omp`, `omp-managed` and `ompu` on your PATH. The managed
`defaults.yml`, `policy.yml` and `untrusted.yml` are baked into the package;
bare `omp` retains the operator's mutable configuration.

Home Manager supervises the shared OMP auth broker on managed machines.
Its supported commands and credential custody remain OMP's; this package
does not generate identities or copy authentication into Code.

## How the managed layering stays reliable

`omp-managed` runs `omp` with the managed
config layered via `--config` at higher precedence than your machine config, so the managed
paths (model roles, retry/fallback, advisor, thinking level, approvals, isolation, …) always
resolve to their Nix-owned values. Editing them in `~/.omp` — or in a running session — does
**not** change them; the overlay wins on every launch. To change the managed base, edit the
dotfiles and reapply; to change the bare `omp`, edit `~/.omp`.

## In these dotfiles

Normally consumed via the Home-Manager module in
[`../../modules/home/agent-tools/contract.nix`](../../modules/home/agent-tools/contract.nix), which installs the
launchers and wires the supporting config. The standalone `nix profile install` path above is
for sharing the toolkit with others without adopting the whole dotfiles.
