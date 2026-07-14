# ADR 0001: Capability-based host composition

- Status: Accepted
- Date: 2026-07-14

## Context

The repository configures several machines with overlapping but non-identical
needs — a Linux development box, macOS laptops, and a headless server — across
two platforms (NixOS/Home Manager and nix-darwin). The naive approach, one
bespoke configuration file per host, duplicates shared setup and lets hosts
drift apart silently. What each machine is *for* (does it run agents? is it a
server? a desktop?) is the real axis of variation, not its hostname.

## Decision

Hosts are entries in a **registry** ([`hosts/default.nix`](../../hosts/default.nix))
that declares each machine's identity, platform, and **capabilities** rather than
its packages or modules directly. Configuration is composed from capability and
profile modules ([`home/profiles/`](../../home/profiles/)); a host turns on the
capabilities it needs (e.g. `agent-tools`, `desktop`, `server`) and inherits the
modules and packages those capabilities own. The registry is the single source
of host truth, and a public projection of it is committed so bootstrap can read
host identity before Nix is available.

See [hosts.md](../hosts.md) and [portable-profiles.md](../portable-profiles.md).

## Consequences

- Adding a machine is registering a host and selecting capabilities, not writing
  a new configuration tree — the "Adding a machine" flow in the docs suffices.
- Shared behavior lives in one capability module, so hosts cannot quietly drift;
  a change to a capability reaches every host that declares it.
- Capabilities are the seam for reuse: the capability modules are exported so
  other Home Manager configurations can consume them (see ADR 0003 for how
  packages attach to layers).
- Checks assert the registry against its committed projection and against each
  host's expected capabilities, so a mismatch fails CI rather than a machine.
