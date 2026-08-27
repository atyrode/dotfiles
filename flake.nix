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

    skhd-zig-tap = {
      url = "github:jackielii/homebrew-tap";
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
      skhd-zig-tap,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      targets = import ./lib/targets.nix { inherit lib nix-index-database; };
      inherit (targets)
        capabilityDescriptions
        capabilityModules
        hosts
        hostsTsv
        knownCapabilities
        mkHostIdentityModule
        publicBootstrapProfiles
        publicHosts
        publicTargets
        selectHomeManagerProfiles
        serverPolicy
        systems
        targetRegistryJson
        ;

      forAllSystems = lib.genAttrs systems;

      packagesLib = import ./lib/packages.nix {
        inherit
          lib
          nixpkgs
          self
          targets
          ;
      };
      inherit (packagesLib)
        agentToolsOverlay
        allowedUnfreePackages
        mkPackageOverlay
        repositoryPkgsFor
        windowsPackageInventory
        ;

      configurations = import ./lib/configurations.nix {
        inherit
          lib
          nixpkgs
          home-manager
          nix-darwin
          nix-homebrew
          nixos-wsl
          homebrew-core
          homebrew-cask
          skhd-zig-tap
          targets
          ;
        packages = packagesLib;
      };
      inherit (configurations)
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

      treefmtEval = forAllSystems (
        system: treefmt-nix.lib.evalModule (repositoryPkgsFor system) ./checks/treefmt.nix
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
          mkPortableHomeConfiguration
          selectHomeManagerProfiles
          ;
        bootstrapProfiles = publicBootstrapProfiles;
        capabilities = knownCapabilities;
        inherit capabilityDescriptions;
        hostRegistry = publicHosts;
        serverProfile = serverPolicy;
        targetRegistry = publicTargets;
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
          pkgs = repositoryPkgsFor system;
        in
        {
          inherit (pkgs)
            atyrode
            atyrode-tui
            code
            codex
            codex-seed
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
          pkgs = repositoryPkgsFor system;
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
            atyrodeTuiPackage = pkgs.atyrode-tui;
            hostRegistry = publicTargets // {
              fixture-nixos = {
                id = "fixture-nixos";
                activation = "nixos";
                capabilities = [
                  "base"
                  "development"
                  "containers"
                ];
                dotfilesDirectory = "/home/fixture/nix-dotfiles";
                homeDirectory = "/home/fixture";
                hostname = null;
                nixTrustedUsers = [
                  "root"
                  "fixture"
                ];
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
          registryFile = pkgs.writeText "atyrode-target-registry.json" targetRegistryJson;
          registryCheck =
            pkgs.runCommand "check-host-registry-${system}"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                jq -e '
                  length >= 7
                  and all(.[];
                    (.id | type == "string")
                    and (.identityMode | IN("fixed", "runtime"))
                    and (.activation | IN("home-manager", "nix-darwin", "nixos-wsl"))
                    and (.system | type == "string")
                    and (.description | type == "string" and length > 0)
                    and (.capabilities | length > 0)
                    and (
                      if .identityMode == "runtime" then
                        .activation == "home-manager"
                        and .platform == "linux"
                        and (has("username") | not)
                        and (has("homeDirectory") | not)
                      else
                        (.username | type == "string")
                        and (.homeDirectory | startswith("/"))
                      end
                    ))
                  and ([.[].capabilities[]] | index("server") | not)
                ' ${registryFile} >/dev/null
                if ! diff ${pkgs.writeText "hosts-expected.tsv" hostsTsv} ${./inventory/hosts.tsv}; then
                  echo 'inventory/hosts.tsv is out of date with hosts/default.nix and hosts/bootstrap.nix' >&2
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
          window-management = import ./checks/window-management.nix {
            inherit lib pkgs;
            darwinConfig = canonicalDarwinConfigs.alex-aarch64-darwin;
            homeConfig = canonicalHomeConfigs.alex-aarch64-darwin;
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
          portable-profile-contract = import ./checks/portable-profile-contract.nix {
            inherit lib mkPortableHomeConfiguration pkgs;
            profileName = "development-${system}";
            fixedHomeConfig =
              canonicalHomeConfigs.${
                {
                  "aarch64-linux" = "alex-aarch64-linux";
                  "x86_64-linux" = "alex-x86_64-linux";
                }
                .${system}
              };
          };
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
          pkgs = repositoryPkgsFor system;
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
          atyrodeApp = {
            type = "app";
            program = "${pkgs.atyrode}/bin/atyrode";
            meta.description = "Manage atyrode dotfiles and infrastructure";
          };
        in
        {
          default = atyrodeApp;
          atyrode = atyrodeApp;
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
