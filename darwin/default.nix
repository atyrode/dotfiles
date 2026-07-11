{
  config,
  homeDirectory,
  homeModules,
  homebrew-cask,
  homebrew-core,
  pkgs,
  username,
  ...
}:

{
  system = {
    primaryUser = username;
    stateVersion = 7;
  };

  # nh's system-profile step runs nix under sudo, where the process-scoped
  # NIX_CONFIG from bootstrap does not reach; root falls back to
  # /etc/nix/nix.conf, which the upstream installer writes without flakes.
  # Owning the setting here keeps every activation phase self-sufficient.
  nix.settings.experimental-features = [
    "flakes"
    "nix-command"
  ];

  users.users.${username}.home = homeDirectory;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "backup";

    users.${username} = {
      imports = homeModules;

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
      "arduino-ide"
      "bitwarden"
      "codex-app"
      "display-pilot"
      "discord"
      "parsec"
      "plugdata"
      "sonos"
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
