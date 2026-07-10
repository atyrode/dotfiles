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

      capabilityModules = {
        base = ./home/profiles/base.nix;
        development = ./home/profiles/development.nix;
        agent-tools = ./home/profiles/agent-tools.nix;
        desktop = ./home/profiles/desktop.nix;
        containers = ./home/profiles/containers.nix;
        media = ./home/profiles/media.nix;
        mobile = ./home/profiles/mobile.nix;
        security = ./home/profiles/security.nix;
        server = ./home/profiles/server.nix;
      };
      knownCapabilities = builtins.attrNames capabilityModules;
      rawHosts = import ./hosts;

      validateHost =
        name: host:
        let
          expectedPlatform = if lib.hasSuffix "-darwin" host.system then "darwin" else "linux";
          capabilities = host.capabilities or [ ];
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
        assert lib.assertMsg (capabilities != [ ]) "host ${name} must select at least one capability";
        assert lib.assertMsg (builtins.elem "base" capabilities)
          "host ${name} must select the base capability";
        assert lib.assertMsg (
          !(builtins.elem "server" capabilities && builtins.elem "desktop" capabilities)
        ) "host ${name} cannot combine server and desktop capabilities";
        assert lib.assertMsg (
          builtins.length capabilities == builtins.length (lib.unique capabilities)
        ) "host ${name} declares duplicate capabilities";
        assert lib.assertMsg (lib.all (
          capability: builtins.hasAttr capability capabilityModules
        ) capabilities) "host ${name} declares an unknown capability";
        assert lib.assertMsg (
          builtins.length aliases == builtins.length (lib.unique aliases)
        ) "host ${name} declares duplicate aliases";
        host
        // {
          inherit aliases capabilities;
          dotfilesDirectory = host.dotfilesDirectory or "${host.homeDirectory}/nix-dotfiles";
          hostname = host.hostname or null;
        };

      validatedHosts = lib.mapAttrs validateHost rawHosts;
      canonicalHostNames = builtins.attrNames validatedHosts;
      allHostAliases = lib.concatMap (name: validatedHosts.${name}.aliases) canonicalHostNames;
      hosts =
        assert lib.assertMsg (
          builtins.length allHostAliases == builtins.length (lib.unique allHostAliases)
        ) "host aliases must be globally unique";
        assert lib.assertMsg (lib.all (
          alias: !(builtins.hasAttr alias validatedHosts)
        ) allHostAliases) "host aliases must not collide with canonical host names";
        validatedHosts;

      publicHost = name: host: {
        id = name;
        inherit (host)
          aliases
          capabilities
          dotfilesDirectory
          homeDirectory
          hostname
          platform
          system
          username
          ;
      };
      publicHosts = lib.mapAttrs publicHost hosts;
      hostRegistryJson = builtins.toJSON publicHosts;

      mkHostIdentityModule = name: host: {
        home.sessionVariables = {
          ATYRODE_HOST = name;
          ATYRODE_CAPABILITIES = lib.concatStringsSep "," host.capabilities;
        };

        xdg.configFile."atyrode/host.json".text = builtins.toJSON (publicHost name host);
      };

      modulesForHost =
        name: host:
        map (capability: capabilityModules.${capability}) host.capabilities
        ++ [
          nix-index-database.homeModules.default
          {
            programs.nix-index-database.comma.enable = true;
            programs.nix-index.enable = true;
          }
          (mkHostIdentityModule name host)
        ];

      agentToolsOverlay = lib.composeManyExtensions [
        herdr.overlays.default
        (final: _previous: {
          agent-tools-migrate = final.callPackage ./pkgs/agent-tools-migrate { };
          herdr-configured = final.callPackage ./pkgs/herdr-configured { };
          herdr-omp-integration = final.callPackage ./pkgs/herdr-omp-integration { };
          omp = final.callPackage ./pkgs/omp { };
          omp-agents = final.callPackage ./pkgs/omp-agents { };
          omp-configured = final.callPackage ./pkgs/omp-configured { };
          atyrode = final.callPackage ./pkgs/atyrode {
            hostRegistry = publicHosts;
          };
        })
      ];

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = package: builtins.elem (lib.getName package) allowedUnfreePackages;
          overlays = [ agentToolsOverlay ];
        };

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
            ./darwin
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
        capabilities = knownCapabilities;
        hostRegistry = publicHosts;
      };

      overlays.default = agentToolsOverlay;

      homeManagerModules.agent-tools = import ./modules/home/agent-tools.nix;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (pkgs)
            agent-tools-migrate
            atyrode
            herdr
            herdr-configured
            herdr-omp-integration
            omp
            omp-agents
            omp-configured
            ;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
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
                  length >= 6
                  and all(.[];
                    (.id | type == "string")
                    and (.system | type == "string")
                    and (.username | type == "string")
                    and (.homeDirectory | startswith("/"))
                    and (.capabilities | length > 0))
                ' ${registryFile} >/dev/null
                mkdir "$out"
              '';
        in
        import ./checks/agent-tools.nix { inherit lib pkgs; }
        // {
          atyrode-cli = import ./checks/atyrode-cli.nix { inherit pkgs; };
          home-evaluation = homeEvaluation;
          host-registry = registryCheck;
          package-ownership = import ./checks/package-ownership.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
          shell-surface = import ./checks/shell-surface.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
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
