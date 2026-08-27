{
  dotfiles,
  nixpkgs,
  system,
  homeDirectory ? "/home/fixture",
  username ? "fixture",
}:

let
  hostId = "fixture-server";
  # The reviewed portable server capability set, not a hand copy: the fixture
  # exists to prove the NixOS-imported composition matches the standalone
  # profile, so its selection must follow the same source of truth.
  inherit ((builtins.fromJSON (builtins.readFile ../../inventory/server-profile.json))) capabilities;
  host = {
    inherit
      capabilities
      homeDirectory
      system
      username
      ;
    activation = "nixos";
    platform = "linux";
    nixTrustedUsers = [
      "root"
      username
    ];
  };
  registry = {
    ${hostId} = host;
  };
  profiles = dotfiles.homeModules.profiles;
in
{
  inherit
    capabilities
    host
    hostId
    registry
    ;

  configuration = nixpkgs.lib.nixosSystem {
    inherit system;

    modules = [
      dotfiles.nixosModules.dotfiles-home
      (
        { pkgs, ... }:
        {
          boot.isContainer = true;
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";

          programs.zsh.enable = true;

          atyrode.dotfiles.hostRegistry = registry;

          users.users.${username} = {
            home = homeDirectory;
            isNormalUser = true;
            shell = pkgs.zsh;
          };

          home-manager.users.${username} = {
            imports = map (name: profiles.${name}) capabilities ++ [
              (dotfiles.lib.mkHostIdentityModule {
                inherit host;
                name = hostId;
              })
            ];

            home = {
              inherit homeDirectory username;
            };
          };
        }
      )
    ];
  };
}
