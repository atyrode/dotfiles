# Architecture documentation

Durable documentation for this dotfiles repository — how it is composed, where
state lives, and the conventions behind it. Each topic has one owning document;
link here rather than duplicating guidance. Implementation history lives in Git,
not in a checklist.

## Map

| Document | Covers |
| --- | --- |
| [system-boundary.md](system-boundary.md) | Home Manager vs system (nix-darwin) ownership and the Homebrew convergence policy |
| [hosts.md](hosts.md) | The host registry (`fleet/hosts.nix`): identity, platform, and capabilities |
| [portable-profiles.md](portable-profiles.md) | The capability modules exported for reuse in other Home Manager configs |
| [package-ownership.md](package-ownership.md) | Evaluated capability/package inventory and its semantic authority boundaries |
| [bootstrap.md](bootstrap.md) | The supported path from an unmanaged machine to a managed one, and activation |
| [atyrode.md](atyrode.md) | The `atyrode` CLI — applying and inspecting the configuration |
| [git-keys.md](git-keys.md) | SSH-first Git authentication/signing, public allowed signers, and machine-key lifecycle |
| [secrets.md](secrets.md) | Secrets and their audience: sops-nix, the operator and machine identities, enrolment and revocation |
| [manifold.md](manifold.md) | The `manifold-node` fleet spoke: enrollment, operator-timed agent upgrades, and master migration |
| [agent-tools.md](agent-tools.md) | OMP, the `code` profile generator, agents, and rules |
| [`tui-visual-verification`](../modules/home/agents/skills/tui-visual-verification/SKILL.md) | Headless TUI verification — character-exact geometry, data-dependent responsive contracts, and conditional pixel inspection |
| [agent-security.md](agent-security.md) | Trust tiers and the managed OMP policy for untrusted content |
| [shell.md](shell.md) | The interactive shell surface (a launcher, not a dev environment) |
| [codex-state.md](codex-state.md) | Codex mutable configuration and the one-time defaults seed |
| [adr/](adr/README.md) | Architecture decision records — the *why* behind the conventions above |

The topic docs above describe how each area works; the [ADRs](adr/README.md)
record why the boundaries and conventions exist. When a doc explains a choice
that had real alternatives, it links to the ADR rather than re-arguing it.

## Adding a machine

Register the host in [`fleet/hosts.nix`](../fleet/hosts.nix) (see
[hosts.md](hosts.md)), then follow [bootstrap.md](bootstrap.md). The
documentation above is intended to be sufficient without chat history.
