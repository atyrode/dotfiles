{
  description = "Dotfiles managed with Nix and Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
  };

  outputs = { self, nixpkgs, home-manager, ... }: {
    homeConfigurations = {
      user = home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs { system = "x86_64-linux"; };

        home = {
          username = "user";
          homeDirectory = "/home/user";

          configuration.imports = [
            ./home.nix  # Main configuration file
          ];
        };
      };
    };
  };
}
