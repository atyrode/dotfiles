# Architecture documentation

Durable documentation for this dotfiles repository — how it is composed, where
state lives, and the conventions behind it. Each topic has one owning document;
link here rather than duplicating guidance. Implementation history lives in Git,
not in a checklist.

## Map

| Document | Covers |
| --- | --- |
| [system-boundary.md](system-boundary.md) | Home Manager vs system (nix-darwin) ownership and the Homebrew convergence policy |
| [hosts.md](hosts.md) | The host registry (`hosts/default.nix`): identity, platform, and capabilities |
| [portable-profiles.md](portable-profiles.md) | The capability modules exported for reuse in other Home Manager configs |
| [package-ownership.md](package-ownership.md) | Which layer owns each package ([`inventory/packages.json`](../inventory/packages.json)) |
| [bootstrap.md](bootstrap.md) | The supported path from an unmanaged machine to a managed one, and activation |
| [atyrode.md](atyrode.md) | The `atyrode` CLI — applying and inspecting the configuration |
| [agent-tools.md](agent-tools.md) | OMP, model presets, agents, rules, and the `code` picker |
| [agent-security.md](agent-security.md) | Trust tiers and the managed OMP policy for untrusted content |
| [shell.md](shell.md) | The interactive shell surface (a launcher, not a dev environment) |
| [codex-state.md](codex-state.md) | Codex mutable configuration and profile state |

## Adding a machine

Register the host in [`hosts/default.nix`](../hosts/default.nix) (see
[hosts.md](hosts.md)), then follow [bootstrap.md](bootstrap.md). The
documentation above is intended to be sufficient without chat history.

## Not yet documented

Architecture decision records (ADRs) for choices with meaningful alternatives or
migration cost are still to be written — tracked in #15.
