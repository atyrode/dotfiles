# Home Manager, nix-darwin, NixOS-WSL, and portable/server configuration
# constructors, plus the server fixtures/manifests and the per-system
# inventory built from the evaluated configurations.
{
  self,
  lib,
  clan-core,
  home-manager,
  nix-homebrew,
  nixos-wsl,
  sops-nix,
  homebrew-core,
  homebrew-cask,
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
    flakeInputPackageNames
    inventoryRevision
    mkPackageOverlay
    repositoryPackageNames
    repositoryPkgsFor
    ;

  forAllSystems = lib.genAttrs systems;

  darwinModule = ../modules/darwin;
  clanMachineModule = ../modules/shared/clan-machine.nix;

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
    import ../checks/fleet/server-profile.nix {
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

  # The system-owned hosts are clan machines (ADR 0008 amendment). The host
  # registry stays the source of truth: the machine list is derived from it,
  # and each machine's module list is exactly what the standalone constructors
  # used before clan-core built them. The per-host values the constructors
  # used to pass as `specialArgs` arrive through `_module.args` instead,
  # because clan's `specialArgs` is one set for every machine. None of them is
  # consumed in an `imports` list, so the difference is invisible to the
  # modules.
  darwinMachineModule = name: host: {
    _module.args = {
      inherit homebrew-cask homebrew-core;
      inherit (host) homeDirectory username;
      homeModules = modulesForHost name host;
    };
    imports = [
      home-manager.darwinModules.home-manager
      nix-homebrew.darwinModules.nix-homebrew
      # clan-core's clanCore already imports sops-nix's darwin module from
      # the same (followed) revision; the module system deduplicates the
      # path, so the explicit import stays for readers.
      sops-nix.darwinModules.sops
      darwinModule
      clanMachineModule
      {
        nixpkgs.hostPlatform = host.system;
        nixpkgs.overlays = [ agentToolsOverlay ];
        nixpkgs.config.allowUnfreePredicate =
          package: builtins.elem (lib.getName package) allowedUnfreePackages;
      }
    ];
  };

  nixosWslMachineModule = name: host: {
    _module.args = {
      inherit host;
      hostId = name;
      homeModules = modulesForHost name host;
      hostRegistry = hosts;
    };
    imports = [
      nixos-wsl.nixosModules.default
      sops-nix.nixosModules.sops
      dotfilesHomeNixosModule
      ../modules/nixos/wsl.nix
      clanMachineModule
    ];
  };

  # Standalone Home Manager hosts are invisible to clan and read no secret;
  # the clan machines are exactly the system-owned hosts, one class each.
  darwinHosts = lib.filterAttrs (_name: host: host.activation == "nix-darwin") hosts;
  nixosWslHosts = lib.filterAttrs (_name: host: host.activation == "nixos-wsl") hosts;
  clanHosts = darwinHosts // nixosWslHosts;

  # The fleet layer. `fleet/hosts.nix` stays the only place a machine is
  # named: the inventory is a projection of it, tagged by activation and
  # platform so a clan service can later select machines the way the
  # registry already describes them. `self` is what the clan CLI reads the
  # secrets and vars directories relative to.
  clan = clan-core.lib.clan {
    inherit self;
    meta.name = "atyrode";
    inventory.machines = lib.mapAttrs (_name: host: {
      machineClass = if host.activation == "nix-darwin" then "darwin" else "nixos";
      inherit (host) description;
      tags = [
        host.activation
        host.platform
      ];
    }) clanHosts;
    machines = lib.mapAttrs (
      name: host:
      if host.activation == "nix-darwin" then
        darwinMachineModule name host
      else
        nixosWslMachineModule name host
    ) clanHosts;
  };

  canonicalHomeConfigs = lib.mapAttrs mkHomeConfig hosts;
  homeManagerHosts = lib.filterAttrs (_name: host: host.activation == "home-manager") hosts;
  standaloneHomeConfigs = lib.mapAttrs mkHomeConfig homeManagerHosts;
  canonicalDarwinConfigs = clan.config.darwinConfigurations;
  canonicalNixosWslConfigs = clan.config.nixosConfigurations;

  inventoryBySystem = forAllSystems (
    system:
    import ../fleet {
      inherit
        capabilityModules
        flakeInputPackageNames
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

  # Every host closure a given system can realise, keyed by host id, as the
  # artifact `atyrode apply` activates on that host: the standalone Home
  # Manager activation package for home-manager hosts, and the system
  # toplevel for the nix-darwin and NixOS-WSL hosts, whose Home Manager
  # profile is embedded in the toplevel rather than activated on its own. CI
  # builds this set per system and pushes it to the fleet binary cache, so a
  # host missing here is a host whose apply rebuilds from source.
  fleetClosuresFor =
    system:
    let
      onSystem = lib.filterAttrs (name: _config: hosts.${name}.system == system);
    in
    lib.mapAttrs (_name: config: config.activationPackage) (onSystem standaloneHomeConfigs)
    // lib.mapAttrs (_name: config: config.system) (onSystem canonicalDarwinConfigs)
    // lib.mapAttrs (_name: config: config.config.system.build.toplevel) (
      onSystem canonicalNixosWslConfigs
    );

in
{
  inherit
    canonicalDarwinConfigs
    canonicalHomeConfigs
    canonicalNixosWslConfigs
    clan
    darwinHosts
    darwinModule
    dotfilesHomeNixosModule
    fleetClosuresFor
    inventoryBySystem
    mkPortableHomeConfiguration
    mkServerHomeConfig
    serverHomeConfigs
    serverProfileManifests
    standaloneHomeConfigs
    ;
}
