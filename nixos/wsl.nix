{
  host,
  hostId,
  homeModules,
  hostRegistry,
  lib,
  pkgs,
  ...
}:

let
  inherit (host) username;
in
{
  assertions = [
    {
      assertion = host.activation == "nixos-wsl";
      message = "${hostId} must be owned by the nixos-wsl activation backend";
    }
    {
      assertion = host.platform == "linux";
      message = "${hostId} must retain the Linux platform contract inside WSL";
    }
    {
      assertion = host.hostname != null;
      message = "${hostId} must declare a stable WSL hostname";
    }
  ];

  nixpkgs.hostPlatform = lib.mkDefault host.system;

  wsl = {
    enable = true;
    defaultUser = username;
    interop = {
      register = true;
      includePath = true;
    };
    wslConf.interop = {
      enabled = true;
      appendWindowsPath = true;
    };
  };

  networking.hostName = host.hostname;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  programs.zsh.enable = true;
  users.users.${username}.shell = pkgs.zsh;

  atyrode.dotfiles.hostRegistry = hostRegistry;
  home-manager = {
    backupFileExtension = "backup";
    users.${username} = {
      imports = homeModules;
      home = {
        inherit username;
        inherit (host) homeDirectory;
      };
    };
  };

  # Native bootstrap and the CLI use this non-secret marker to distinguish the
  # managed distribution from an unrelated NixOS WSL instance with the same name.
  environment.etc."atyrode/wsl-host.json".text = builtins.toJSON {
    schemaVersion = 1;
    id = hostId;
    inherit (host) activation;
    inherit (host) hostname system username;
  };

  system.stateVersion = "26.05";
}
