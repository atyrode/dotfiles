# Portable Home Manager profiles

This flake exports the same capability modules used by its local Home Manager
and nix-darwin configurations. A NixOS consumer can therefore select a small,
reviewed user environment without importing a workstation host or copying its
configuration.

The dependency is deliberately one-way: infrastructure pins this flake;
dotfiles never imports the infrastructure repository. NixOS owns privileged
filesystems, networking, the firewall, the Nix daemon, system services,
container runtimes, account login shells, device rules, backups, and production
secrets. The consuming flake also owns hostnames, provider identifiers, user
names, and home paths. The cross-platform ownership matrix and readiness
diagnostics are documented in [Home Manager and system
boundary](system-boundary.md).

## Exported contract

- `homeModules.profiles` contains the portable `base`, `development`,
  `agent-tools`, `server`, `desktop`, `containers`, `media`, `mobile`, and
  `security` capability modules. These are the exact modules used locally.
- `lib.selectHomeManagerProfiles` validates a named capability selection and
  returns its modules. Every selection requires `base`; `server` is Linux-only
  and cannot be combined with `development` or `desktop`.
- `lib.mkPackageOverlay { hostRegistry = ...; }` builds repository packages
  against a consumer-supplied, non-secret host registry.
- `lib.mkHostIdentityModule` materializes an identity only when a consumer
  explicitly supplies one.
- `nixosModules.dotfiles-home` wires Home Manager, the package overlay, and the
  reviewed unfree-package allowlist into NixOS. Its
  `atyrode.dotfiles.hostRegistry` option defaults to an empty registry; Home
  Manager uses the resulting global package set and user packages by default.
- `homeModules.agent-tools` retains its earlier meaning as the low-level
  configurable agent-tools module. New compositions should use
  `homeModules.profiles.agent-tools`.
- `darwinModules.default` remains the separate nix-darwin/Mac system layer.

The reviewed server selection is recorded in
`lib.serverProfile.capabilities` as `base + server + agent-tools`. It excludes
development quality tools, desktop/media/mobile packages, container clients,
and security scanners. Compatible optional capabilities require an explicit,
reviewed infrastructure change; the portable default stays lean.

## NixOS consumer

The infrastructure flake should make the dotfiles `nixpkgs` and Home Manager
inputs follow its own pins, then import the integration module. This abbreviated
example intentionally leaves every production system option in the consumer:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    dotfiles.url = "github:atyrode/dotfiles/<reviewed-revision>";
    dotfiles.inputs.nixpkgs.follows = "nixpkgs";
    dotfiles.inputs.home-manager.follows = "home-manager";
  };

  outputs = { dotfiles, nixpkgs, ... }:
    let
      hostId = "server-id";
      host = {
        system = "x86_64-linux";
        platform = "linux";
        activation = "home-manager";
        username = "<server-user>";
        homeDirectory = "/home/<server-user>";
        capabilities = [ "base" "server" "agent-tools" ];
      };
    in {
      nixosConfigurations.${hostId} = nixpkgs.lib.nixosSystem {
        system = host.system;
        modules = [
          dotfiles.nixosModules.dotfiles-home
          ({ pkgs, ... }: {
            atyrode.dotfiles.hostRegistry.${hostId} = host;

            users.users.${host.username} = {
              isNormalUser = true;
              home = host.homeDirectory;
              shell = pkgs.zsh;
            };

            programs.zsh.enable = true;

            home-manager.users.${host.username} = {
              imports = [
                dotfiles.homeModules.profiles.base
                dotfiles.homeModules.profiles.server
                dotfiles.homeModules.profiles.agent-tools
                (dotfiles.lib.mkHostIdentityModule {
                  name = hostId;
                  inherit host;
                })
              ];
              home = {
                inherit (host) homeDirectory username;
              };
            };

            # Nix daemon policy, networking, filesystems, services, device
            # rules, container engines, secrets, and backups live here.
          })
        ];
      };
    };
}
```

`checks/fixtures/nixos-server.nix` continuously evaluates this interface as an
arbitrary NixOS Home Manager user. The fixture has no provider hostname,
network, disk, service, secret, or application inventory.

## Manifest and budget

Linux systems export `packages.<system>.server-profile-manifest`. Its
`manifest.json` records the system, selected and excluded capabilities,
evaluated top-level package names, state ownership boundaries, and actual and
maximum closure measurements. `home-activation` points at the exact evaluated
Home Manager generation. The manifest contains no identity or production
facts, and the repository-wide production-facts check enforces the same rule
for every tracked file: no address literals, providers, or datacenter
identifiers.

At the pinned 2026-07-08 nixpkgs revision, x86_64 Linux delivers 37 top-level
packages (Claude Code joined the agent baseline) and measures 2,376,988,648
NAR bytes across 406 store paths. Its review ceilings are 40 packages,
2,617,245,696 bytes, and 450 paths: roughly ten percent headroom, with bytes
rounded up to a 64 MiB boundary. The aarch64 Linux ceilings
are 40 packages, 2.5 GiB, and 500 paths and are enforced on the native CI
runner. A dependency update that exceeds a ceiling must explain the growth and
deliberately update `inventory/server-profile.json`.

Inspect a candidate revision before updating infrastructure:

```sh
nix build 'github:atyrode/dotfiles/<revision>#server-profile-manifest'
jq . result/manifest.json
```

## Pin and update workflow

1. Select a dotfiles commit whose three native CI jobs pass.
2. Build and inspect its server manifest for the target architecture.
3. Replace the `dotfiles.url` revision with that full immutable commit SHA, then
   run `nix flake update dotfiles` and review both `flake.nix` and `flake.lock`.
4. Evaluate the NixOS host, review the closure diff, and use the
   infrastructure repository's normal staged rollout.
5. Roll back by restoring the previous lock-file revision and rebuilding the
   host. Home Manager generations remain user-environment rollback points; they
   are not capability profiles.

Credentials, agent authentication, sessions, caches, and project trust remain
mutable outside the Nix store and outside the manifest.
