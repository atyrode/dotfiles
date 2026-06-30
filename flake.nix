{
  description = "atyrode dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

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

    homeDirectoryFor = system: username:
      if lib.hasSuffix "-darwin" system
      then "/Users/${username}"
      else "/home/${username}";

    # Helper function to create home configuration
    mkHomeConfig = { system, username ? defaultUsername, homeDirectory ? homeDirectoryFor system username }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        modules = [
          ./home
          {
            home.username = username;
            home.homeDirectory = homeDirectory;
          }
        ];
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
          }
        ];
      };

    configs = forAllSystems (system: mkHomeConfig { inherit system; });
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
      };

    darwinConfigurations =
      lib.mapAttrs' (
        system: config:
          lib.nameValuePair "${defaultUsername}-${system}" config
      ) darwinConfigs
      // {
        "${defaultUsername}-darwin" = darwinConfigs.${defaultDarwinSystem};
      };

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
