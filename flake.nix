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

    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };

    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    herdr,
    nix-darwin,
    nix-homebrew,
    homebrew-core,
    homebrew-cask,
    ...
  }:
  let
    lib = nixpkgs.lib;

    defaultUsername = "alex";

    hostAliases = {
      "ubuntu-4gb-nbg1-1" = "x86_64-linux";
    };

    systems = [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    darwinSystems = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];

    # Safe fallback for bare `home-manager --flake .` invocations.
    # Shell helpers should still select an explicit system-specific config.
    defaultSystem = "x86_64-linux";
    defaultDarwinSystem = "aarch64-darwin";

    forAllSystems = lib.genAttrs systems;

    agentToolsOverlay = lib.composeManyExtensions [
      herdr.overlays.default
      (final: _previous: {
        agent-tools-migrate = final.callPackage ./pkgs/agent-tools-migrate { };
        herdr-configured = final.callPackage ./pkgs/herdr-configured { };
        herdr-omp-integration = final.callPackage ./pkgs/herdr-omp-integration { };
        omp = final.callPackage ./pkgs/omp { };
        omp-agents = final.callPackage ./pkgs/omp-agents { };
        omp-configured = final.callPackage ./pkgs/omp-configured { };
      })
    ];

    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ agentToolsOverlay ];
      };

    homeDirectoryFor = system: username:
      if lib.hasSuffix "-darwin" system
      then "/Users/${username}"
      else "/home/${username}";

    # Helper function to create home configuration
    mkHomeConfig = {
      system,
      username ? defaultUsername,
      homeDirectory ? homeDirectoryFor system username,
      extraModules ? [ ],
    }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor system;

        modules =
          [
            ./home
            {
              home.username = username;
              home.homeDirectory = homeDirectory;
            }
          ]
          ++ extraModules;
      };

    mkDarwinConfig = { system, username ? defaultUsername, homeDirectory ? homeDirectoryFor system username }:
      nix-darwin.lib.darwinSystem {
        specialArgs = {
          inherit
            homeDirectory
            homebrew-cask
            homebrew-core
            username
            ;
        };

        modules = [
          home-manager.darwinModules.home-manager
          nix-homebrew.darwinModules.nix-homebrew
          ./darwin
          {
            nixpkgs.hostPlatform = system;
            nixpkgs.overlays = [ agentToolsOverlay ];
          }
        ];
      };

    configs = forAllSystems (system: mkHomeConfig { inherit system; });
    linuxDesktopConfigs = {
      "x86_64-linux" = mkHomeConfig {
        system = "x86_64-linux";
        extraModules = [ ./home/linux-desktop.nix ];
      };
    };
    darwinConfigs = lib.genAttrs darwinSystems (system: mkDarwinConfig { inherit system; });
  in {
    homeConfigurations =
      {
        # Default configuration for bare Home Manager invocations.
        ${defaultUsername} = configs.${defaultSystem};
      }
      // lib.mapAttrs' (
        system: config:
          lib.nameValuePair "${defaultUsername}-${system}" config
      ) configs
      // lib.mapAttrs' (
        hostname: system:
          lib.nameValuePair "${defaultUsername}@${hostname}" configs.${system}
      ) hostAliases
      // {
        "${defaultUsername}-darwin" = configs.${defaultDarwinSystem};
        "${defaultUsername}-linux" = configs."x86_64-linux";
        "${defaultUsername}-linux-desktop" = linuxDesktopConfigs."x86_64-linux";
        "${defaultUsername}-x86_64-linux-desktop" = linuxDesktopConfigs."x86_64-linux";
      };

    darwinConfigurations =
      lib.mapAttrs' (
        system: config:
          lib.nameValuePair "${defaultUsername}-${system}" config
      ) darwinConfigs
      // {
        "${defaultUsername}-darwin" = darwinConfigs.${defaultDarwinSystem};
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
        homeEvaluation = builtins.deepSeq configs.${system}.activationPackage.drvPath (
          pkgs.runCommand "check-home-evaluation-${system}" { } ''
            mkdir "$out"
          ''
        );
        darwinEvaluation = builtins.deepSeq darwinConfigs.${system}.system.drvPath (
          pkgs.runCommand "check-darwin-evaluation-${system}" { } ''
            mkdir "$out"
          ''
        );
      in
      import ./checks/agent-tools.nix { inherit lib pkgs; }
      // {
        home-evaluation = homeEvaluation;
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
