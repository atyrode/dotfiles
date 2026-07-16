# omp-configured — the `code` profile generator

`omp-configured` packages [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`), the
coding-agent launcher, plus **`code`** — an interactive TUI that builds an OMP routing
profile from a prompt (or a few dials) and launches it, with a per-provider usage panel.

## What you get

- **`code`** — the profile generator (Bubble Tea TUI). Type a prompt and/or adjust the
  facet dials (lane, model tier, thinking, spark, fable — plus, while fable is on, a
  "main" sub-dial that hands Fable the default-agent role; that escalation is manual
  only, never suggested); a local prompt→profile classifier
  (running on the resident ollama daemon) suggests settings. The usage widget
  names the active authentication vault; **`a`** cycles enabled vaults and
  **`v`** opens the vault manager for all-vault usage, selection, enable/disable,
  refresh, and provider login. **Enter** launches the generated routing profile,
  layered over the managed defaults and policy. Every trusted launch and usage
  fetch stays in the shared OMP client profile `default` while the selected
  auth-broker vault supplies credentials.

  Press **`m`** to launch the managed defaults without a generated overlay,
  **`u`** to open the fixed untrusted sandbox for the current directory, or `?`
  for all keys.
- **`omp`** — passthrough to your own **unmanaged** `~/.omp` config (the one mutable base;
  `omp update` is blocked since the package is Nix-managed).
- **`omp-managed`** — the managed-layering primitive: platform extensions + managed defaults
  + policy applied to a one-shot `--config`. This is the launch target `code` uses for a
  generated profile; it is also useful directly.
- **`ompu`** — a sandboxed launcher for untrusted repositories (stripped credentials,
  restricted tools/approvals, sanitized state).

The generator's model catalog and cost figures live in
[`../../omp/models.yml`](../../omp/models.yml) (synced from `omp models`).
The repository's versioned [OMP feature wiki](../../docs/omp/README.md) catalogs
upstream CLI flags and less-obvious capabilities; this README remains
authoritative for the four wrappers above.

## Install it standalone (Nix)

This package is a **flake output**, so it does **not** require the rest of these dotfiles. On
any machine that has Nix and uses `omp`:

```sh
nix profile install github:atyrode/dotfiles#omp-configured
```

That puts `code`, `omp`, `omp-managed`, and `ompu` on your PATH. It's self-contained:

- The managed config (`defaults.yml`, `policy.yml`, `untrusted.yml`) and the generated
  routing grid are **baked into the package**.
- Your bare `omp` configuration remains mutable. `code` keeps trusted client
  sessions/settings in profile `default` and changes only its auth-broker
  environment.
- The wrapper reads machine-local vault metadata from
  `$XDG_CONFIG_HOME/atyrode/code-auth-vaults.json`; `CODE_AUTH_VAULTS` can
  provide a read-only override. Without either source it falls back to the local
  OMP `default` profile, keeping the package neutral. The `code` vault manager
  can create entries and rename display labels only in the machine-local file.
  Home Manager's identity-agnostic broker supervisor validates that file and
  automatically reloads valid atomic changes while retaining current brokers
  after an invalid edit; it never generates vault identities.
- Broker bearer tokens remain mutable mode-0600 files outside the Nix store and
  are read fresh for each usage fetch or launch. The selected vault therefore
  cannot diverge between the displayed quota and subsequent session.

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
