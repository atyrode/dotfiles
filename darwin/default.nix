{
  config,
  homeDirectory,
  homebrew-cask,
  homebrew-core,
  pkgs,
  username,
  ...
}:

{
  nixpkgs.config.allowUnfree = true;

  system = {
    primaryUser = username;
    stateVersion = 7;
  };

  users.users.${username}.home = homeDirectory;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";

    users.${username} = {
      imports = [ ../home ];

      home = {
        inherit username homeDirectory;
      };
    };
  };

  nix-homebrew = {
    enable = true;
    enableRosetta = pkgs.stdenv.hostPlatform.isAarch64;
    user = username;
    autoMigrate = true;

    taps = {
      "homebrew/homebrew-core" = homebrew-core;
      "homebrew/homebrew-cask" = homebrew-cask;
    };

    mutableTaps = false;
  };

  homebrew = {
    enable = true;
    taps = builtins.attrNames config.nix-homebrew.taps;

    casks = [
      "steam"
      "zen"
    ];

    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "none";
    };
  };
}
