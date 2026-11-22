# omp-configured — managed and untrusted launchers

`omp-configured` packages [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`)
with declarative launch policy.

## What you get

- **`omp`** — passthrough to your own **unmanaged** `~/.omp` config (the one mutable base;
  `omp update` is blocked since the package is Nix-managed).
- **`omp-managed`** — platform extensions, managed defaults and policy applied
  through a one-shot `--config`, without replacing the operator's configuration.
- **`ompu`** — a sandboxed launcher for untrusted repositories (stripped credentials,
  restricted tools/approvals, sanitized state).

Agent prompts and routing come from the pinned OMP bundle: task uses `task`,
scout/sonic use `smol`, and reviewer uses `slow`; security-reviewer and seance
retain native inheritance. The launchers do not emit per-agent model overrides.
Existing writable overrides are preserved, not silently migrated by seeding;
review and remove those separately before expecting native routing.

Use the pinned binaries' `--help` output for upstream behavior; this README
describes the three operator launchers.

## Install it standalone (Nix)

This package is a **flake output**, so it does **not** require the rest of these dotfiles. On
any machine that has Nix and uses `omp`:

```sh
nix profile install github:atyrode/dotfiles#omp-configured
```

That puts `omp`, `omp-managed` and `ompu` on your PATH. The managed
defaults, policy and untrusted posture
are baked into the package; bare `omp` retains the operator's mutable
configuration.

Home Manager supervises the shared OMP auth broker on managed machines.
Its supported commands and credential custody remain OMP's.

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
