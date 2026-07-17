{
  dotfiles,
  nixpkgs,
  system,
  homeDirectory ? "/home/fixture",
  username ? "fixture",
}:

let
  hostId = "fixture-server";
  capabilities = [
    "base"
    "server"
    "agent-tools"
  ];
  host = {
    inherit
      capabilities
      homeDirectory
      system
      username
      ;
    platform = "linux";
    aliases = [ ];
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
            imports = [
              profiles.base
              profiles.server
              profiles.agent-tools
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
