{
  description = "atyrode dotfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
  let
    lib = nixpkgs.lib;

    defaultUsername = "alex";

    systems = [
      "aarch64-darwin"
      "x86_64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];

    defaultSystem = "aarch64-darwin";

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

    configs = forAllSystems (system: mkHomeConfig { inherit system; });
  in {
    homeConfigurations =
      {
        # Default configuration for this Mac.
        ${defaultUsername} = configs.${defaultSystem};
      }
      // lib.mapAttrs' (
        system: config:
          lib.nameValuePair "${defaultUsername}-${system}" config
      ) configs
      // {
        "${defaultUsername}-darwin" = configs.${defaultSystem};
        "${defaultUsername}-linux" = configs."x86_64-linux";
      };

    apps = forAllSystems (system: {
      home-manager = {
        type = "app";
        program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
      };
    });
  };
}
