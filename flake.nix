{
  description = "atyrode dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    nixos-wsl.url = "github:nix-community/NixOS-WSL";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

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
      home-manager,
      nix-darwin,
      nix-homebrew,
      nixos-wsl,
      nix-index-database,
      treefmt-nix,
      homebrew-core,
      homebrew-cask,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = lib.genAttrs systems;

      # Each name corresponds to a reviewed package in a selected capability.
      # Homebrew casks are governed independently by the nix-darwin module.
      allowedUnfreePackages = [
        "arduino-ide"
        "chatgpt"
        "claude-code"
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
        "whatsapp-for-mac"
      ];
      homebrewCasks = import ./darwin/casks.nix;
      windowsPackageInventory = import ./windows/packages.nix;

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
      inventoryAnnotations = import ./inventory/annotations.nix;
      capabilityDescriptions = lib.mapAttrs (
        _: annotation: annotation.purpose
      ) inventoryAnnotations.capabilities;
      capabilitySummary =
        assert lib.assertMsg (
          builtins.attrNames capabilityDescriptions == knownCapabilities
        ) "capability annotations must cover the capability set exactly";
        map (name: {
          inherit name;
          description = capabilityDescriptions.${name};
        }) knownCapabilities;
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
          activation = host.activation or null;
          capabilities = validateCapabilities {
            inherit name;
            inherit (host) system;
            capabilities = host.capabilities or [ ];
          };
        in
        assert lib.assertMsg (builtins.elem host.system systems)
          "host ${name} uses unsupported system ${host.system}";
        assert lib.assertMsg (
          host.platform == expectedPlatform
        ) "host ${name} platform ${host.platform} does not match ${host.system}";
        assert lib.assertMsg (builtins.elem activation [
          "home-manager"
          "nix-darwin"
          "nixos-wsl"
        ]) "host ${name} must declare a supported activation owner";
        assert lib.assertMsg (
          if host.platform == "darwin" then
            activation == "nix-darwin"
          else
            builtins.elem activation [
              "home-manager"
              "nixos-wsl"
            ]
        ) "host ${name} activation owner ${toString activation} does not match platform ${host.platform}";
        assert lib.assertMsg (
          activation != "nixos-wsl" || builtins.isString (host.hostname or null)
        ) "NixOS-WSL host ${name} must declare a stable hostname";
        assert lib.assertMsg (
          builtins.isString host.username && host.username != ""
        ) "host ${name} must declare a non-empty username";
        assert lib.assertMsg (
          builtins.isString host.homeDirectory && lib.hasPrefix "/" host.homeDirectory
        ) "host ${name} must declare an absolute homeDirectory";
        assert lib.assertMsg (builtins.isString (
          host.description or ""
        )) "host ${name} description must be a string";
        host
        // {
          inherit capabilities;
          inherit activation;
          description = host.description or "";
          hostname = host.hostname or null;
        };

      validateHostRegistry = registry: lib.mapAttrs validateHost registry;

      hosts = validateHostRegistry rawHosts;

      publicHost = name: host: {
        id = name;
        inherit (host)
          activation
          capabilities
          description
          homeDirectory
          hostname
          platform
          system
          username
          ;
      };
      publicHosts = lib.mapAttrs publicHost hosts;
      bootstrapHosts = lib.filterAttrs (_: host: host.activation != "nixos-wsl") publicHosts;
      hostRegistryJson = builtins.toJSON publicHosts;
      # Flat projection consumed by the macOS/Linux get.sh before Nix exists;
      # NixOS-WSL has its own native get.ps1 boundary. The host-registry check
      # keeps the committed bootstrap-eligible projection honest.
      hostsTsv = lib.concatMapStrings (
        name:
        let
          host = bootstrapHosts.${name};
        in
        "${name}\t${host.system}\t${lib.concatStringsSep "," host.capabilities}\t${host.description}\n"
      ) (builtins.attrNames bootstrapHosts);

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

      repositoryPackageNames = [
        "atyrode"
        "atyrode-tui"
        "code"
        "codex"
        "atyrode-codex-seed"
        "herdr"
        "orca-ide"
        "omp"
        "omp-agents"
        "omp-configured"
        "atyrode-omp-seed"
      ];

      mkPackageOverlay =
        {
          hostRegistry ? { },
        }:
        let
          publicRegistry = lib.mapAttrs publicHost (validateHostRegistry hostRegistry);
        in
        lib.composeManyExtensions [
          (final: _previous: {
            atyrode-tui = final.callPackage ./pkgs/atyrode-tui { };
            # Repository-owned on every platform: upstream releases outpace
            # nixpkgs, which also cannot build codex on aarch64-darwin.
            code = final.callPackage ./pkgs/code { };
            codex = final.callPackage ./pkgs/codex-bin { };
            codex-seed = final.callPackage ./pkgs/codex-seed { };
            herdr = final.callPackage ./pkgs/herdr { };
            orca-ide = final.callPackage ./pkgs/orca-ide { };
            omp = final.callPackage ./pkgs/omp { };
            omp-agents = final.callPackage ./pkgs/omp-agents { };
            omp-configured = final.callPackage ./pkgs/omp-configured { };
            omp-seed = final.callPackage ./pkgs/omp-seed { };
            atyrode = final.callPackage ./pkgs/atyrode {
              capabilities = capabilitySummary;
              inherit homebrewCasks;
              hostRegistry = publicRegistry;
              revision = inventoryRevision;
              windowsPackages = windowsPackageInventory;
            };
          })
          (
            _final: previous:
            lib.optionalAttrs previous.stdenv.isDarwin {
              # nixpkgs Darwin fixup replaces Obsidian's Developer ID signature
              # with an ad-hoc one. The pinned upstream DMG and derivation audit
              # in #89 verified that skipping fixup preserves its signed bundle.
              obsidian = previous.obsidian.overrideAttrs (_: {
                dontFixup = true;
              });
              # nixpkgs Darwin fixup replaces Spotify's Developer ID signature
              # with an ad-hoc one, breaking macOS privacy identity (TN3179).
              # The focused test in #89 validated that skipping fixup preserves it.
              spotify = previous.spotify.overrideAttrs (_: {
                dontFixup = true;
              });
              # nixpkgs Darwin fixup likewise replaces VLC's verified upstream
              # Developer ID signature even though the derivation only repacks
              # the app bundle and creates a wrapper outside it (#89).
              vlc-bin = previous.vlc-bin.overrideAttrs (_: {
                dontFixup = true;
              });
            }
          )
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

      treefmtEval = forAllSystems (
        system: treefmt-nix.lib.evalModule (pkgsFor system) ./checks/treefmt.nix
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
            ./nixos/wsl.nix
          ];
        };

      canonicalHomeConfigs = lib.mapAttrs mkHomeConfig hosts;
      homeManagerHosts = lib.filterAttrs (_name: host: host.activation == "home-manager") hosts;
      standaloneHomeConfigs = lib.mapAttrs mkHomeConfig homeManagerHosts;
      darwinHosts = lib.filterAttrs (_name: host: host.activation == "nix-darwin") hosts;
      canonicalDarwinConfigs = lib.mapAttrs mkDarwinConfig darwinHosts;
      nixosWslHosts = lib.filterAttrs (_name: host: host.activation == "nixos-wsl") hosts;
      canonicalNixosWslConfigs = lib.mapAttrs mkNixosWslConfig nixosWslHosts;
      inventoryRevision = self.rev or self.dirtyRev or "dirty";
      inventoryBySystem = forAllSystems (
        system:
        import ./inventory {
          inherit
            capabilityModules
            home-manager
            hosts
            lib
            repositoryPackageNames
            system
            ;
          annotations = inventoryAnnotations;
          pkgs = pkgsFor system;
          revision = inventoryRevision;
          homeConfigs = lib.filterAttrs (name: _: hosts.${name}.system == system) canonicalHomeConfigs;
          darwinConfigs = lib.filterAttrs (
            name: _: darwinHosts.${name}.system == system
          ) canonicalDarwinConfigs;
        }
      );

    in
    {
      homeConfigurations = standaloneHomeConfigs;

      darwinConfigurations = canonicalDarwinConfigs;
      nixosConfigurations = canonicalNixosWslConfigs;
      inventory = inventoryBySystem;
      capabilityInventory = lib.mapAttrs (_: manifest: manifest.capabilities) inventoryBySystem;

      lib = {
        inherit
          allowedUnfreePackages
          mkHostIdentityModule
          mkPackageOverlay
          selectHomeManagerProfiles
          ;
        capabilities = knownCapabilities;
        inherit capabilityDescriptions;
        hostRegistry = publicHosts;
        serverProfile = serverPolicy;
        windowsPackages = windowsPackageInventory;
      };

      overlays.default = agentToolsOverlay;

      homeModules = {
        # Nix's recognized community schema for reusable Home Manager modules.
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
            atyrode
            atyrode-tui
            code
            codex
            codex-seed
            herdr
            orca-ide
            omp
            omp-agents
            omp-configured
            omp-seed
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
          cockpitStub = pkgs.writeShellScriptBin "atyrode-tui" ''
            printf 'cockpit:%s:%s\n' "$ATYRODE_CLI" "$#"
          '';
          systemDoctorAtyrode = pkgs.atyrode.override {
            enableTestHooks = true;
            atyrode-tui = cockpitStub;
            atyrode-preview-parser = pkgs.atyrode-tui;
            hostRegistry = publicHosts // {
              fixture-server = {
                id = "fixture-server";
                activation = "home-manager";
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
                activation = "home-manager";
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
                    and (.activation | IN("home-manager", "nix-darwin", "nixos-wsl"))
                    and (.system | type == "string")
                    and (.username | type == "string")
                    and (.homeDirectory | startswith("/"))
                    and (.description | type == "string" and length > 0)
                    and (.capabilities | length > 0))
                  and ([.[].capabilities[]] | index("server") | not)
                ' ${registryFile} >/dev/null
                if ! diff ${pkgs.writeText "hosts-expected.tsv" hostsTsv} ${./inventory/hosts.tsv}; then
                  echo 'inventory/hosts.tsv is out of date with hosts/default.nix' >&2
                  exit 1
                fi
                mkdir "$out"
              '';
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
                "aarch64-linux" = "alex-aarch64-linux";
                "x86_64-linux" = "alex-x86_64-linux";
              }
              .${system};
          };
          bootstrap = import ./checks/bootstrap.nix { inherit pkgs; };
          codex-seed = import ./checks/codex-seed.nix { inherit pkgs; };
          get-entrypoint = import ./checks/get-sh.nix { inherit pkgs; };
          herdr = import ./checks/herdr.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
          orca = import ./checks/orca.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
          rio = import ./checks/rio.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
          omp-seed = import ./checks/omp-seed.nix { inherit pkgs; };
          omp-secret-obfuscation = import ./checks/omp-secret-obfuscation.nix { inherit pkgs; };
          omp-isolated-writer = import ./checks/omp-isolated-writer.nix { inherit pkgs; };
          omp-vault-usage-footer = import ./checks/omp-vault-usage-footer.nix { inherit pkgs; };
          home-evaluation = homeEvaluation;
          host-registry = registryCheck;
          package-ownership = import ./checks/package-ownership.nix {
            inherit pkgs;
            inventory = inventoryBySystem.${system};
          };
          shell-surface = import ./checks/shell-surface.nix {
            inherit lib pkgs;
            hostConfigs = canonicalHomeConfigs;
          };
          system-boundary = import ./checks/system-boundary.nix {
            inherit lib pkgs system;
            inventory = inventoryBySystem.${system};
            homeConfigs = systemHomeConfigs;
            serverConfig = if isLinux then serverHomeConfig.config else null;
            externalFixture = if isLinux then externalServerFixture else null;
            darwinConfigs = systemDarwinConfigs;
          };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Platform-independent lints: their output is a pure function of the
          # source tree, so emitting them on every system just re-runs the same
          # work three times in CI. Keep them on one leg only (#169).
          # docs-links and production-facts scan the whole tree (docs
          # included); they are the two intentional exceptions the docs-only
          # fast path builds directly and scripts/docs-drift-guard.sh excludes.
          docs-links = import ./checks/docs-links.nix { inherit lib pkgs; };
          docs-drift-guard = import ./checks/docs-drift-guard.nix { inherit pkgs; };
          classify-ci-paths = import ./checks/classify-ci-paths.nix { inherit pkgs; };
          production-facts = import ./checks/production-facts.nix { inherit pkgs; };
          treefmt = treefmtEval.${system}.config.build.check treefmtSources;
          windows = import ./checks/windows.nix {
            inherit lib pkgs;
            nixosConfig = canonicalNixosWslConfigs.alex-x86_64-linux-wsl;
            windowsPackages = windowsPackageInventory;
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
          obsidian-signature = import ./checks/obsidian-signature.nix {
            inherit pkgs;
            inherit (pkgs) obsidian;
          };
          spotify-signature = import ./checks/spotify-signature.nix {
            inherit pkgs;
            inherit (pkgs) spotify;
          };
          vlc-signature = import ./checks/vlc-signature.nix {
            inherit pkgs;
            inherit (pkgs) vlc-bin;
          };
        }
      );

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          # Re-pull the factual fields in omp/models.yml from omp (cost/context via
          # `omp models`, speed/ttft via `omp bench`). Run from the repo root:
          #   nix run .#refresh-model-facts [-- --skip-bench | --runs 3 | …]
          refreshModelFacts = pkgs.writeShellApplication {
            name = "refresh-model-facts";
            runtimeInputs = [
              (pkgs.python3.withPackages (ps: [ ps.ruamel-yaml ]))
              pkgs.omp
            ];
            text = ''python3 ${./omp/refresh-model-facts.py} "$@"'';
          };
        in
        {
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
            meta.description = "Run Home Manager configurations";
          };
          refresh-model-facts = {
            type = "app";
            program = "${refreshModelFacts}/bin/refresh-model-facts";
            meta.description = "Refresh OMP model cost, context, and benchmark facts";
          };
        }
        // lib.optionalAttrs (lib.hasSuffix "-darwin" system) {
          darwin-rebuild = {
            type = "app";
            program = "${nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild";
            meta.description = "Run nix-darwin configurations";
          };
        }
      );
    };
}
