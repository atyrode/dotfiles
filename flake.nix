{
  description = "atyrode dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Babel is the fleet's archival instrument for agent session history
    # (atyrode/babel SPEC.md 2.3): restic to a Cellar bucket under a stable
    # host identity, catalogued in a shared PostgreSQL. Pinned as a flake
    # input rather than re-packaged under pkgs/, because its derivation is a
    # plain buildGoModule with a fixed vendorHash. flake.lock carries the
    # exact revision the hourly archive timer executes.
    babel.url = "github:atyrode/babel";
    babel.inputs.nixpkgs.follows = "nixpkgs";

    # The preview executor uses Manifold's own declared owner/transport
    # profile; the ordinary fleet agent remains independently release-pinned.
    manifold.url = "github:atyrode/manifold";
    manifold.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    # The fleet layer (ADR 0008 amendment): clan-core builds the nix-darwin
    # and NixOS machines, so each machine class carries clan's vars over
    # sops-nix and the operator's `clan` CLI reads this flake as its clan.
    # Pinned to the same 26.05 release tarball the operator's existing clan
    # consumes; every input clan-core shares with this flake follows ours so
    # each module is evaluated from exactly one revision.
    clan-core.url = "https://git.clan.lol/clan/clan-core/archive/26.05.tar.gz";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";
    clan-core.inputs.nix-darwin.follows = "nix-darwin";
    clan-core.inputs.sops-nix.follows = "sops-nix";
    clan-core.inputs.treefmt-nix.follows = "treefmt-nix";
    clan-core.inputs.disko.follows = "disko";

    # What clan vars decrypt with at activation: sops-nix's nixos and darwin
    # modules, each machine holding its own age key. Followed by clan-core.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # What a NixOS machine of this fleet is installed and identified by: disko
    # partitions its disk from the machine's own declaration and nixos-facter
    # supplies the hardware facts its report captured, so a destroyed machine
    # is rebuilt from this repository rather than from a remembered install.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };

    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      babel,
      manifold,
      clan-core,
      disko,
      home-manager,
      nix-homebrew,
      nixos-wsl,
      nixos-facter-modules,
      nix-index-database,
      sops-nix,
      treefmt-nix,
      homebrew-core,
      homebrew-cask,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      targets = import ./lib/targets.nix { inherit lib nix-index-database; };
      inherit (targets) systems;

      forAllSystems = lib.genAttrs systems;

      packagesLib = import ./lib/packages.nix {
        inherit
          babel
          clan-core
          lib
          nixpkgs
          self
          targets
          ;
      };
      inherit (packagesLib) repositoryPkgsFor;

      configurations = import ./lib/configurations.nix {
        inherit
          self
          lib
          clan-core
          disko
          home-manager
          manifold
          nix-homebrew
          nixos-facter-modules
          nixos-wsl
          sops-nix
          homebrew-core
          homebrew-cask
          targets
          ;
        packages = packagesLib;
      };
      inherit (configurations)
        canonicalDarwinConfigs
        canonicalNixosConfigs
        clan
        fleetClosuresFor
        mkPortableHomeConfiguration
        ;

      treefmtEval = forAllSystems (
        system: treefmt-nix.lib.evalModule (repositoryPkgsFor system) ./checks/lints/treefmt.nix
      );

      # Keep unrelated documentation changes from invalidating the gate while
      # automatically covering every file type handled by the treefmt module.
      treefmtSources = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          (lib.fileset.fileFilter (
            file:
            file.name == ".envrc"
            || lib.hasPrefix ".envrc." file.name
            || file.hasExt "bash"
            || file.hasExt "go"
            || file.hasExt "nix"
            || file.hasExt "sh"
            || file.hasExt "yaml"
            || file.hasExt "yml"
          ) ./.)
          # The atyrode CLI is a first-class shell program without an .sh
          # extension; ShellCheck gates it via an explicit include.
          ./pkgs/atyrode/atyrode
        ];
      };

    in
    {
      darwinConfigurations = canonicalDarwinConfigs;
      nixosConfigurations = canonicalNixosConfigs;
      # The clan CLI locates machines through these two outputs
      # (`clan machines update` reads `clanInternals.machines.<system>.<name>`).
      clan = clan.config;
      inherit (clan.config) clanInternals;

      # The one output another flake reads: the adapter `atyrode apply` writes
      # for a portable profile builds its Home Manager configuration from here.
      lib = {
        inherit mkPortableHomeConfiguration;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = repositoryPkgsFor system;
        in
        {
          inherit (pkgs)
            atyrode
            atyrode-preview
            codex
            codex-seed
            code
            omp
            omp-agents
            omp-configured
            omp-seed
            ;
          # One root per system for the fleet binary cache: CI builds this
          # and copies its closure, so every host below activates from a
          # download. Members are named by host id for inspection.
          fleet-closures = pkgs.linkFarm "fleet-closures-${system}" (
            lib.mapAttrsToList (name: path: { inherit name path; }) (fleetClosuresFor system)
          );
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          development-image = pkgs.callPackage ./pkgs/development-image {
            inherit mkPortableHomeConfiguration;
            revision = self.rev or self.dirtyRev or "dirty";
          };
        }
      );

      checks = forAllSystems (
        system:
        import ./checks {
          inherit
            lib
            system
            targets
            configurations
            ;
          packages = packagesLib;
          pkgs = repositoryPkgsFor system;
          treefmtCheck = treefmtEval.${system}.config.build.check treefmtSources;
        }
      );

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      apps = forAllSystems (
        system:
        let
          pkgs = repositoryPkgsFor system;
          atyrodeApp = {
            type = "app";
            program = "${pkgs.atyrode}/bin/atyrode";
            meta.description = "Manage atyrode dotfiles and infrastructure";
          };
        in
        {
          default = atyrodeApp;
          atyrode = atyrodeApp;
        }
      );
    };
}
