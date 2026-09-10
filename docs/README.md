# Architecture documentation

Durable documentation for this dotfiles repository — how it is composed, where
state lives, and the conventions behind it. Each topic has one owning document;
link here rather than duplicating guidance. Implementation history lives in Git,
not in a checklist.

## Map

| Document | Covers |
| --- | --- |
| [day-to-day.md](day-to-day.md) | Running the fleet: converging a machine, adding one, adding a device, and what `doctor` is for |
| [system-boundary.md](system-boundary.md) | Home Manager vs system (nix-darwin) ownership and the Homebrew convergence policy |
| [hosts.md](hosts.md) | The host registry (`fleet/hosts.nix`): identity, platform, and capabilities |
| [bootstrap.md](bootstrap.md) | The only supported path from an unmanaged machine to a registered host: what bootstrap owns before it relays to `atyrode apply`, repairs, failure codes, recovery |
| [atyrode.md](atyrode.md) | What the `atyrode` CLI promises: the mutation boundary, what reaches the terminal, and where its identities and surfaces come from (`atyrode --help` is the syntax) |
| [secrets.md](secrets.md) | Secrets and their audience: sops-nix, the operator and machine identities, enrolment and revocation |
| [manifold.md](manifold.md) | The `manifold-node` capability: a spoke of the self-hosted hub, its enrollment, operator-timed agent upgrades, and master migration |
| [agent-tools.md](agent-tools.md) | OMP launchers, shared authentication, agents, and rules |
| [`tui-visual-verification`](../modules/home/agents/skills/tui-visual-verification/SKILL.md) | Headless TUI verification — character-exact geometry, data-dependent responsive contracts, and conditional pixel inspection |
| [agent-security.md](agent-security.md) | Trust tiers and the managed OMP policy for untrusted content |
| [shell.md](shell.md) | The interactive shell surface (a launcher, not a dev environment) |
| [codex-state.md](codex-state.md) | Codex mutable configuration and the one-time defaults seed |
| [adr/](adr/README.md) | Architecture decision records — the *why* behind the conventions above |

The topic docs above describe how each area works; the [ADRs](adr/README.md)
record why the boundaries and conventions exist. When a doc explains a choice
that had real alternatives, it links to the ADR rather than re-arguing it.

## Adding a machine

[day-to-day.md](day-to-day.md#adding-a-machine) has the four steps; a machine
with no Nix at all starts one step earlier, with [bootstrap.md](bootstrap.md).
The documentation above is intended to be sufficient without chat history.
