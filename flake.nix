{
  description = "atyrode dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    herdr.url = "github:ogulcancelik/herdr/v0.7.3";
    herdr.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

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
      home-manager,
      herdr,
      nix-darwin,
      nix-homebrew,
      nix-index-database,
      homebrew-core,
      homebrew-cask,
      ...
    }:
    let
      lib = nixpkgs.lib;

      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = lib.genAttrs systems;

      # Each name corresponds to a reviewed package in a selected capability.
      # Homebrew casks are governed independently by the nix-darwin module.
      allowedUnfreePackages = [
        "arduino-ide"
        "chatgpt"
        "codex"
        "obsidian"
        "orbstack"
        "parsec-bin"
        "postman"
        "reaper"
        "signal-desktop"
        "spotify"
        "steam"
        "steam-original"
        "steam-unwrapped"
        "steamcmd"
        "vital"
        "vscode"
        "whatsapp-for-mac"
      ];
      homebrewCasks = import ./darwin/casks.nix;

      rawCapabilityModules = import ./home/profiles;

      mkCapabilityModule = name: module: {
        imports = [
          ./modules/home/capability-contract.nix
          module
        ];

        atyrode.capabilities.selected = [ name ];
      };

      capabilityModules = lib.mapAttrs mkCapabilityModule rawCapabilityModules // {
        base = {
          imports = [
            ./modules/home/capability-contract.nix
            rawCapabilityModules.base
            nix-index-database.homeModules.default
          ];

          atyrode.capabilities.selected = [ "base" ];
          programs.nix-index.enable = true;
          programs.nix-index-database.comma.enable = true;
        };
      };
      knownCapabilities = builtins.attrNames capabilityModules;
      serverPolicy = builtins.fromJSON (builtins.readFile ./inventory/server-profile.json);
      serverCapabilities = serverPolicy.capabilities;
      darwinModule = ./darwin;
      rawHosts = import ./hosts;

      validateCapabilities =
        {
          capabilities,
          name ? "composition",
          system,
        }:
        assert lib.assertMsg (builtins.elem system systems) "${name} uses unsupported system ${system}";
        assert lib.assertMsg (capabilities != [ ]) "${name} must select at least one capability";
        assert lib.assertMsg (builtins.elem "base" capabilities) "${name} must select the base capability";
        assert lib.assertMsg (
          !(builtins.elem "server" capabilities && builtins.elem "desktop" capabilities)
        ) "${name} cannot combine server and desktop capabilities";
        assert lib.assertMsg (
          !(builtins.elem "server" capabilities && builtins.elem "development" capabilities)
        ) "${name} cannot combine server and development capabilities";
        assert lib.assertMsg (
          !builtins.elem "server" capabilities || lib.hasSuffix "-linux" system
        ) "${name} can select the server capability only on Linux";
        assert lib.assertMsg (
          builtins.length capabilities == builtins.length (lib.unique capabilities)
        ) "${name} declares duplicate capabilities";
        assert lib.assertMsg (lib.all (
          capability: builtins.hasAttr capability capabilityModules
        ) capabilities) "${name} declares an unknown capability";
        capabilities;

      validateHost =
        name: host:
        let
          expectedPlatform = if lib.hasSuffix "-darwin" host.system then "darwin" else "linux";
          capabilities = validateCapabilities {
            inherit name;
            inherit (host) system;
            capabilities = host.capabilities or [ ];
          };
          aliases = host.aliases or [ ];
        in
        assert lib.assertMsg (builtins.elem host.system systems)
          "host ${name} uses unsupported system ${host.system}";
        assert lib.assertMsg (
          host.platform == expectedPlatform
        ) "host ${name} platform ${host.platform} does not match ${host.system}";
        assert lib.assertMsg (
          builtins.isString host.username && host.username != ""
        ) "host ${name} must declare a non-empty username";
        assert lib.assertMsg (
          builtins.isString host.homeDirectory && lib.hasPrefix "/" host.homeDirectory
        ) "host ${name} must declare an absolute homeDirectory";
        assert lib.assertMsg (
          builtins.length aliases == builtins.length (lib.unique aliases)
        ) "host ${name} declares duplicate aliases";
        host
        // {
          inherit aliases capabilities;
          hostname = host.hostname or null;
        };

      validateHostRegistry =
        registry:
        let
          validated = lib.mapAttrs validateHost registry;
          canonicalNames = builtins.attrNames validated;
          aliases = lib.concatMap (name: validated.${name}.aliases) canonicalNames;
        in
        assert lib.assertMsg (
          builtins.length aliases == builtins.length (lib.unique aliases)
        ) "host aliases must be globally unique";
        assert lib.assertMsg (lib.all (
          alias: !(builtins.hasAttr alias validated)
        ) aliases) "host aliases must not collide with canonical host names";
        validated;

      hosts = validateHostRegistry rawHosts;

      publicHost = name: host: {
        id = name;
        inherit (host)
          aliases
          capabilities
          homeDirectory
          hostname
          platform
          system
          username
          ;
      };
      publicHosts = lib.mapAttrs publicHost hosts;
      hostRegistryJson = builtins.toJSON publicHosts;

      mkHostIdentityModule =
        {
          host,
          name,
        }:
        let
          validated = validateHost name host;
        in
        {
          home.sessionVariables = {
            ATYRODE_HOST = name;
            ATYRODE_CAPABILITIES = lib.concatStringsSep "," validated.capabilities;
          };

          xdg.configFile."atyrode/host.json".text = builtins.toJSON (publicHost name validated);
        };

      selectHomeManagerProfiles =
        {
          capabilities,
          name ? "composition",
          system,
        }:
        map (capability: capabilityModules.${capability}) (validateCapabilities {
          inherit capabilities name system;
        });

      modulesForHost =
        name: host:
        selectHomeManagerProfiles {
          inherit name;
          inherit (host) capabilities system;
        }
        ++ [ (mkHostIdentityModule { inherit host name; }) ];

      mkPackageOverlay =
        {
          hostRegistry ? { },
        }:
        let
          publicRegistry = lib.mapAttrs publicHost (validateHostRegistry hostRegistry);
        in
        lib.composeManyExtensions [
          herdr.overlays.default
          (final: _previous: {
            agent-tools-migrate = final.callPackage ./pkgs/agent-tools-migrate { };
            codex-configured = final.callPackage ./pkgs/codex-configured { };
            codex-use = final.callPackage ./pkgs/codex-use { };
            herdr-configured = final.callPackage ./pkgs/herdr-configured { };
            herdr-omp-integration = final.callPackage ./pkgs/herdr-omp-integration { };
            omp = final.callPackage ./pkgs/omp { };
            omp-agents = final.callPackage ./pkgs/omp-agents { };
            omp-configured = final.callPackage ./pkgs/omp-configured { };
            atyrode = final.callPackage ./pkgs/atyrode {
              capabilities = knownCapabilities;
              inherit homebrewCasks;
              hostRegistry = publicRegistry;
            };
          })
        ];

      agentToolsOverlay = mkPackageOverlay { hostRegistry = rawHosts; };

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

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = package: builtins.elem (lib.getName package) allowedUnfreePackages;
          overlays = [ agentToolsOverlay ];
        };

      portablePkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = package: builtins.elem (lib.getName package) allowedUnfreePackages;
          overlays = [ (mkPackageOverlay { }) ];
        };

      mkServerHomeConfig =
        {
          homeDirectory ? "/home/fixture",
          system,
          username ? "fixture",
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = portablePkgsFor system;
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
        import ./checks/server-profile.nix {
          inherit
            lib
            serverHomeConfig
            serverPolicy
            system
            ;
          pkgs = portablePkgsFor system;
        }
      ) serverHomeConfigs;

      mkHomeConfig =
        name: host:
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsFor host.system;

          modules = modulesForHost name host ++ [
            {
              home.username = host.username;
              home.homeDirectory = host.homeDirectory;
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
              ;
            homeDirectory = host.homeDirectory;
            homeModules = modulesForHost name host;
            username = host.username;
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

      canonicalHomeConfigs = lib.mapAttrs mkHomeConfig hosts;
      darwinHosts = lib.filterAttrs (_name: host: host.platform == "darwin") hosts;
      canonicalDarwinConfigs = lib.mapAttrs mkDarwinConfig darwinHosts;

      aliasesFor =
        selectedHosts: configs:
        lib.foldl' (
          aliases: name:
          aliases
          // builtins.listToAttrs (
            map (alias: lib.nameValuePair alias configs.${name}) selectedHosts.${name}.aliases
          )
        ) { } (builtins.attrNames selectedHosts);
    in
    {
      homeConfigurations = canonicalHomeConfigs // aliasesFor hosts canonicalHomeConfigs;

      darwinConfigurations = canonicalDarwinConfigs // aliasesFor darwinHosts canonicalDarwinConfigs;

      lib = {
        inherit
          allowedUnfreePackages
          mkHostIdentityModule
          mkPackageOverlay
          selectHomeManagerProfiles
          ;
        capabilities = knownCapabilities;
        hostRegistry = publicHosts;
        serverProfile = serverPolicy;
      };

      overlays.default = agentToolsOverlay;

      homeManagerModules = {
        # Preserve the original low-level configurable module export.
        agent-tools = import ./modules/home/agent-tools.nix;
        profiles = capabilityModules;
      };

      nixosModules.dotfiles-home = dotfilesHomeNixosModule;

      darwinModules.default = darwinModule;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (pkgs)
            agent-tools-migrate
            atyrode
            codex-configured
            codex-use
            herdr
            herdr-configured
            herdr-omp-integration
            omp
            omp-agents
            omp-configured
            ;
        }
        // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
          server-profile-manifest = serverProfileManifests.${system};
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          isLinux = lib.hasSuffix "-linux" system;
          serverHomeConfig = if isLinux then serverHomeConfigs.${system} else null;
          alternateServerHomeConfig =
            if isLinux then
              mkServerHomeConfig {
                inherit system;
                homeDirectory = "/home/second-fixture";
                username = "second-fixture";
              }
            else
              null;
          externalServerFixture =
            if isLinux then
              import ./checks/fixtures/nixos-server.nix {
                dotfiles = self;
                inherit nixpkgs system;
              }
            else
              null;
          systemDoctorAtyrode = pkgs.atyrode.override {
            enableTestHooks = true;
            hostRegistry = publicHosts // {
              fixture-server = {
                id = "fixture-server";
                aliases = [ ];
                capabilities = [
                  "base"
                  "server"
                ];
                dotfilesDirectory = "/home/fixture/nix-dotfiles";
                homeDirectory = "/home/fixture";
                hostname = null;
                platform = "linux";
                system = "x86_64-linux";
                username = "fixture";
              };
              fixture-security = {
                id = "fixture-security";
                aliases = [ ];
                capabilities = [
                  "base"
                  "security"
                ];
                dotfilesDirectory = "/home/fixture/nix-dotfiles";
                homeDirectory = "/home/fixture";
                hostname = null;
                platform = "linux";
                system = "x86_64-linux";
                username = "fixture";
              };
            };
          };
          systemHomeConfigs = lib.filterAttrs (
            name: _config: hosts.${name}.system == system
          ) canonicalHomeConfigs;
          systemDarwinConfigs = lib.filterAttrs (
            name: _config: darwinHosts.${name}.system == system
          ) canonicalDarwinConfigs;
          homeEvaluationPaths = lib.mapAttrsToList (
            _name: config: config.activationPackage.drvPath
          ) systemHomeConfigs;
          darwinEvaluationPaths = lib.mapAttrsToList (
            _name: config: config.system.drvPath
          ) systemDarwinConfigs;
          homeEvaluation = builtins.deepSeq homeEvaluationPaths (
            pkgs.runCommand "check-home-evaluation-${system}" { } ''
              mkdir "$out"
            ''
          );
          darwinEvaluation = builtins.deepSeq darwinEvaluationPaths (
            pkgs.runCommand "check-darwin-evaluation-${system}" { } ''
              mkdir "$out"
            ''
          );
          registryFile = pkgs.writeText "atyrode-host-registry.json" hostRegistryJson;
          registryCheck =
            pkgs.runCommand "check-host-registry-${system}"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                jq -e '
                  length >= 5
                  and all(.[];
                    (.id | type == "string")
                    and (.system | type == "string")
                    and (.username | type == "string")
                    and (.homeDirectory | startswith("/"))
                    and (.capabilities | length > 0))
                  and ([.[].capabilities[]] | index("server") | not)
                ' ${registryFile} >/dev/null
                mkdir "$out"
              '';
          baseOnlyConfig = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              capabilityModules.base
              {
                home.username = "fixture";
                home.homeDirectory = if lib.hasSuffix "-darwin" system then "/Users/fixture" else "/home/fixture";
              }
            ];
          };
        in
        import ./checks/agent-tools.nix { inherit lib pkgs; }
        // {
          atyrode-cli = import ./checks/atyrode-cli.nix {
            inherit pkgs;
            atyrode = systemDoctorAtyrode;
            productionAtyrode = pkgs.atyrode;
            productionHost =
              {
                "aarch64-darwin" = "alex-aarch64-darwin";
                "x86_64-darwin" = "alex-x86_64-darwin";
                "aarch64-linux" = "alex-aarch64-linux";
                "x86_64-linux" = "alex-x86_64-linux";
              }
              .${system};
          };
          bootstrap = import ./checks/bootstrap.nix { inherit pkgs; };
          codex-use = import ./checks/codex-use.nix {
            inherit lib pkgs;
            baseConfig = baseOnlyConfig;
          };
          get-entrypoint = import ./checks/get-sh.nix { inherit pkgs; };
          home-evaluation = homeEvaluation;
          host-registry = registryCheck;
          package-ownership = import ./checks/package-ownership.nix {
            inherit lib pkgs serverPolicy;
            serverConfig = if isLinux then serverHomeConfig.config else null;
          };
          shell-surface = import ./checks/shell-surface.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
          system-boundary = import ./checks/system-boundary.nix {
            inherit lib pkgs system;
            homeConfigs = systemHomeConfigs;
            serverConfig = if isLinux then serverHomeConfig.config else null;
            externalFixture = if isLinux then externalServerFixture else null;
            darwinConfigs = systemDarwinConfigs;
          };
        }
        // lib.optionalAttrs isLinux {
          portable-profiles = import ./checks/portable-profiles.nix {
            inherit
              alternateServerHomeConfig
              lib
              pkgs
              selectHomeManagerProfiles
              serverHomeConfig
              serverPolicy
              system
              ;
            externalFixture = externalServerFixture;
            serverProfileManifest = serverProfileManifests.${system};
          };
          server-profile = serverProfileManifests.${system};
        }
        // lib.optionalAttrs (lib.hasSuffix "-darwin" system) {
          darwin-evaluation = darwinEvaluation;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      apps = forAllSystems (
        system:
        {
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
          };
        }
        // lib.optionalAttrs (lib.hasSuffix "-darwin" system) {
          darwin-rebuild = {
            type = "app";
            program = "${nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild";
          };
        }
      );
    };
}
