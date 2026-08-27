# Home Manager, nix-darwin, NixOS-WSL, and portable/server configuration
# constructors, plus the server fixtures/manifests and the per-system
# inventory built from the evaluated configurations.
{
  lib,
  nixpkgs,
  home-manager,
  nix-darwin,
  nix-homebrew,
  nixos-wsl,
  homebrew-core,
  homebrew-cask,
  skhd-zig-tap,
  targets,
  packages,
}:

let
  inherit (targets)
    bootstrapProfiles
    capabilityModules
    hosts
    inventoryAnnotations
    modulesForHost
    publicBootstrapProfile
    selectHomeManagerProfiles
    serverCapabilities
    serverPolicy
    systems
    ;
  inherit (packages)
    agentToolsOverlay
    allowedUnfreePackages
    evaluationPkgsFor
    inventoryRevision
    mkPackageOverlay
    repositoryPackageNames
    repositoryPkgsFor
    ;

  forAllSystems = lib.genAttrs systems;

  darwinModule = ../darwin;

  dotfilesHomeNixosModule =
    { config, lib, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];

      options.atyrode.dotfiles.hostRegistry = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        description = "Non-secret host registry supplied by the consuming NixOS flake.";
      };

      config = {
        home-manager.useGlobalPkgs = lib.mkDefault true;
        home-manager.useUserPackages = lib.mkDefault true;
        nixpkgs.overlays = [
          (mkPackageOverlay { hostRegistry = config.atyrode.dotfiles.hostRegistry; })
        ];
        nixpkgs.config.allowUnfreePredicate = lib.mkDefault (
          package: builtins.elem (lib.getName package) allowedUnfreePackages
        );
      };
    };

  mkServerHomeConfig =
    {
      homeDirectory ? "/home/fixture",
      system,
      username ? "fixture",
    }:
    home-manager.lib.homeManagerConfiguration {
      pkgs = evaluationPkgsFor system;
      modules =
        selectHomeManagerProfiles {
          name = "portable server profile";
          inherit system;
          capabilities = serverCapabilities;
        }
        ++ [
          {
            home = {
              inherit homeDirectory username;
            };
          }
        ];
    };

  serverHomeConfigs = lib.genAttrs serverPolicy.supportedSystems (
    system: mkServerHomeConfig { inherit system; }
  );

  serverProfileManifests = lib.mapAttrs (
    system: serverHomeConfig:
    import ../checks/server-profile.nix {
      inherit
        lib
        serverHomeConfig
        serverPolicy
        system
        ;
      pkgs = evaluationPkgsFor system;
    }
  ) serverHomeConfigs;

  mkHomeConfig =
    name: host:
    home-manager.lib.homeManagerConfiguration {
      pkgs = repositoryPkgsFor host.system;

      modules = modulesForHost name host ++ [
        {
          home.username = host.username;
          home.homeDirectory = host.homeDirectory;
        }
      ];
    };

  mkPortableHomeConfiguration =
    {
      homeDirectory,
      profileName,
      username,
      gitAuthMode ? "ssh",
    }:
    let
      profile =
        bootstrapProfiles.${profileName} or (throw "unknown portable bootstrap profile ${profileName}");
      identity = publicBootstrapProfile profileName profile // {
        inherit
          gitAuthMode
          homeDirectory
          username
          ;
      };
    in
    assert lib.assertMsg (
      builtins.isString username
      && builtins.match "[a-z_][a-z0-9_-]*\\$?" username != null
      && username != "root"
    ) "portable bootstrap profile ${profileName} requires a valid non-root username";
    assert lib.assertMsg (
      builtins.isString homeDirectory && lib.hasPrefix "/" homeDirectory
    ) "portable bootstrap profile ${profileName} requires an absolute homeDirectory";
    assert lib.assertMsg (builtins.elem gitAuthMode [
      "ssh"
      "https-gh"
    ]) "portable bootstrap profile ${profileName} requires gitAuthMode ssh or https-gh";
    home-manager.lib.homeManagerConfiguration {
      pkgs = repositoryPkgsFor profile.system;
      modules =
        selectHomeManagerProfiles {
          name = profileName;
          inherit (profile) capabilities system;
        }
        ++ [
          {
            atyrode.gitAuthMode = gitAuthMode;
            home = {
              inherit homeDirectory username;
              sessionPath = [
                "${homeDirectory}/.local/state/nix/profiles/home-manager/home-path/bin"
              ];
              sessionVariables = {
                ATYRODE_HOST = profileName;
                ATYRODE_CAPABILITIES = lib.concatStringsSep "," profile.capabilities;
                ATYRODE_GIT_AUTH_MODE = gitAuthMode;
                # Browser-hosted terminals choose fonts on the client, so
                # server-installed Nerd Fonts cannot supply Code's PUA
                # glyphs. Keep portable profiles single-cell and readable
                # with an ASCII facet set; fixed machines retain Nerd Font.
                CODE_FACET_GLYPHS = "runtime=@,lane=~,model=#,thinking=?,advisor=&,spark=^,fable=*,main=+,fast=!,relief=%";
              };
            };
            xdg.configFile."atyrode/host.json".text = builtins.toJSON identity;
          }
        ];
    };

  mkDarwinConfig =
    name: host:
    nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          homebrew-cask
          homebrew-core
          skhd-zig-tap
          ;
        inherit (host) homeDirectory;
        homeModules = modulesForHost name host;
        inherit (host) username;
      };

      modules = [
        home-manager.darwinModules.home-manager
        nix-homebrew.darwinModules.nix-homebrew
        darwinModule
        {
          nixpkgs.hostPlatform = host.system;
          nixpkgs.overlays = [ agentToolsOverlay ];
          nixpkgs.config.allowUnfreePredicate =
            package: builtins.elem (lib.getName package) allowedUnfreePackages;
        }
      ];
    };

  mkNixosWslConfig =
    name: host:
    nixpkgs.lib.nixosSystem {
      inherit (host) system;
      specialArgs = {
        inherit host;
        hostId = name;
        homeModules = modulesForHost name host;
        hostRegistry = hosts;
      };
      modules = [
        nixos-wsl.nixosModules.default
        dotfilesHomeNixosModule
        ../nixos/wsl.nix
      ];
    };

  canonicalHomeConfigs = lib.mapAttrs mkHomeConfig hosts;
  homeManagerHosts = lib.filterAttrs (_name: host: host.activation == "home-manager") hosts;
  standaloneHomeConfigs = lib.mapAttrs mkHomeConfig homeManagerHosts;
  darwinHosts = lib.filterAttrs (_name: host: host.activation == "nix-darwin") hosts;
  canonicalDarwinConfigs = lib.mapAttrs mkDarwinConfig darwinHosts;
  nixosWslHosts = lib.filterAttrs (_name: host: host.activation == "nixos-wsl") hosts;
  canonicalNixosWslConfigs = lib.mapAttrs mkNixosWslConfig nixosWslHosts;
  inventoryBySystem = forAllSystems (
    system:
    import ../inventory {
      inherit
        capabilityModules
        home-manager
        hosts
        lib
        repositoryPackageNames
        system
        ;
      annotations = inventoryAnnotations;
      pkgs = repositoryPkgsFor system;
      revision = inventoryRevision;
      homeConfigs = lib.filterAttrs (name: _: hosts.${name}.system == system) canonicalHomeConfigs;
      darwinConfigs = lib.filterAttrs (
        name: _: darwinHosts.${name}.system == system
      ) canonicalDarwinConfigs;
    }
  );
in
{
  inherit
    canonicalDarwinConfigs
    canonicalHomeConfigs
    canonicalNixosWslConfigs
    darwinHosts
    darwinModule
    dotfilesHomeNixosModule
    inventoryBySystem
    mkPortableHomeConfiguration
    mkServerHomeConfig
    serverHomeConfigs
    serverProfileManifests
    standaloneHomeConfigs
    ;
}
