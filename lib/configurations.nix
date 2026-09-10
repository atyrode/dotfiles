# Home Manager, nix-darwin, NixOS-WSL, and portable/server configuration
# constructors, plus the server fixtures/manifests.
{
  self,
  lib,
  clan-core,
  disko,
  home-manager,
  manifold,
  nix-homebrew,
  nixos-facter-modules,
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
    hosts
    modulesForHost
    publicBootstrapProfile
    selectHomeManagerProfiles
    ;
  inherit (packages)
    agentToolsOverlay
    allowedUnfreePackages
    mkPackageOverlay
    repositoryPkgsFor
    ;

  darwinModule = ../modules/darwin;
  clanMachineModules = [
    ../modules/shared/clan-machine.nix
    ../modules/shared/git-identity.nix
    ../modules/shared/babel-archive.nix
    ../modules/shared/omp-auth-broker.nix
    ../modules/shared/manifold-agent.nix
  ];

  # Home Manager inside a NixOS machine of this fleet: the package overlay
  # reads this flake's own registry, so no machine restates it.
  dotfilesHomeNixosModule =
    { lib, ... }:
    {
      imports = [ home-manager.nixosModules.home-manager ];
      config = {
        home-manager.useGlobalPkgs = lib.mkDefault true;
        home-manager.useUserPackages = lib.mkDefault true;
        nixpkgs.overlays = [ (mkPackageOverlay { hostRegistry = hosts; }) ];
        nixpkgs.config.allowUnfreePredicate = lib.mkDefault (
          package: builtins.elem (lib.getName package) allowedUnfreePackages
        );
      };
    };

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
      inherit host homebrew-cask homebrew-core;
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
      {
        nixpkgs.hostPlatform = host.system;
        nixpkgs.overlays = [ agentToolsOverlay ];
        nixpkgs.config.allowUnfreePredicate =
          package: builtins.elem (lib.getName package) allowedUnfreePackages;
      }
    ]
    ++ clanMachineModules;
  };

  nixosWslMachineModule = name: host: {
    _module.args = {
      inherit host;
      hostId = name;
      homeModules = modulesForHost name host;
      # The only address this machine has that the fleet can name: a WSL guest
      # sits behind Windows and the home NAT, so it is deployed over the
      # overlay or not at all.
      overlayDomain = overlayInstance;
    };
    imports = [
      nixos-wsl.nixosModules.default
      sops-nix.nixosModules.sops
      dotfilesHomeNixosModule
      ../modules/nixos/wsl.nix
    ]
    ++ clanMachineModules;
  };

  # A NixOS machine of this fleet owns its whole substrate: disko partitions
  # the disk the machine declares, nixos-facter supplies the hardware facts
  # its report captured, and the machine's own directory under `fleet/` is
  # imported in full so a half-ported machine fails evaluation instead of
  # silently booting without storage, network, or boot authority.
  nixosMachineModule =
    name: host:
    let
      machineDirectory = ../fleet/machines + "/${name}";
    in
    {
      _module.args = {
        inherit host machineDirectory;
        hostId = name;
        homeModules = modulesForHost name host;
      };
      imports = [
        disko.nixosModules.disko
        nixos-facter-modules.nixosModules.facter
        sops-nix.nixosModules.sops
        dotfilesHomeNixosModule
        (machineDirectory + "/disko.nix")
        (machineDirectory + "/network.nix")
        (machineDirectory + "/boot.nix")
        ../modules/nixos/vps.nix
        ../modules/nixos/cloudflare-dns.nix
        ../modules/nixos/myparcelle-dev.nix
        ../modules/nixos/games.nix
      ]
      ++ lib.optionals (name == "dev-01") [
        manifold.nixosModules.native
        ../modules/nixos/manifold-dev-hub.nix
      ]
      ++ clanMachineModules;
    };

  # Every registered host is a clan machine, one class each; the Darwin
  # subset is named because the checks select their configurations by system.
  darwinHosts = lib.filterAttrs (_name: host: host.activation == "nix-darwin") hosts;
  clanHosts = hosts;

  # The fleet layer. `fleet/hosts.nix` stays the only place a machine is
  # named: the inventory is a projection of it, tagged by activation and
  # platform so a clan service can select machines the way the registry
  # already describes them. `self` is what the clan CLI reads the secrets and
  # vars directories relative to.
  #
  # The overlay (ADR 0008 "Identity and reachability", #582) is clan's
  # wireguard service, one instance named `fleet`: the workshop is the
  # controller because it is the one machine with a public address, and every
  # other machine is a peer that dials it from behind whatever NAT it sits
  # in. Keys and the ULA addresses are clan vars, minted by `clan vars
  # generate` and placed at activation; every machine resolves every other as
  # `<name>.fleet` through the hosts file the service writes. What the
  # overlay is for is the substrate: `fleet apply` reaching a machine that
  # exposes no port, and the backup routine reaching the disk at home. It is
  # not manifold's transport -- the agent dials the hub's public origin from
  # anywhere, overlay or not -- and manifold does not read it (docs/manifold.md).
  overlayInstance = "fleet";
  overlayController = "dev-01";
  clan = clan-core.lib.clan {
    inherit self;
    meta.name = "atyrode";
    # The Mac's operator key is a Secure Enclave handle, so every clan
    # command that decrypts with it needs the plugin on its own PATH. Named
    # as a flake reference, not a bare package: clan allowlists the bare
    # names it will put on a PATH and age-plugin-se is not on that list at
    # the pinned revision, while a reference is resolved through its own
    # runtime flake and is not checked. The first `clan vars generate` of the
    # fleet failed on the bare name (#542).
    secrets.age.plugins = [ "nixpkgs#age-plugin-se" ];
    inventory.machines = lib.mapAttrs (_name: host: {
      machineClass = if host.activation == "nix-darwin" then "darwin" else "nixos";
      inherit (host) description;
      tags = [
        host.activation
        host.platform
      ];
    }) clanHosts;
    inventory.instances.${overlayInstance} = {
      module = {
        name = "wireguard";
        input = "clan-core";
      };
      roles.controller.machines.${overlayController}.settings.endpoint = "${
        hosts.${overlayController}.hostname
      }.${(import (../fleet/machines + "/${overlayController}/address.nix")).domain}";
      roles.peer.machines = lib.mapAttrs (_name: _host: { }) (
        lib.filterAttrs (name: _host: name != overlayController) clanHosts
      );
    };
    machines = lib.mapAttrs (
      name: host:
      let
        machineModule = {
          "nix-darwin" = darwinMachineModule;
          "nixos" = nixosMachineModule;
          "nixos-wsl" = nixosWslMachineModule;
        };
      in
      machineModule.${host.activation} name host
    ) clanHosts;
  };

  canonicalHomeConfigs = lib.mapAttrs mkHomeConfig hosts;
  canonicalDarwinConfigs = clan.config.darwinConfigurations;
  canonicalNixosConfigs = clan.config.nixosConfigurations;

  # Every host closure a given system can realise, keyed by host id, as the
  # artifact `atyrode apply` activates on that host: the system toplevel,
  # whose Home Manager profile is embedded rather than activated on its own.
  # CI builds this set per system and pushes it to the fleet binary cache, so
  # a host missing here is a host whose apply rebuilds from source.
  fleetClosuresFor =
    system:
    let
      onSystem = lib.filterAttrs (name: _config: hosts.${name}.system == system);
    in
    lib.mapAttrs (_name: config: config.system) (onSystem canonicalDarwinConfigs)
    // lib.mapAttrs (_name: config: config.config.system.build.toplevel) (
      onSystem canonicalNixosConfigs
    );

in
{
  inherit
    canonicalDarwinConfigs
    canonicalHomeConfigs
    canonicalNixosConfigs
    clan
    darwinHosts
    darwinModule
    dotfilesHomeNixosModule
    fleetClosuresFor
    mkPortableHomeConfiguration
    ;
}
