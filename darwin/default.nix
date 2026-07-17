{
  config,
  homeDirectory,
  homeModules,
  homebrew-cask,
  homebrew-cmux,
  homebrew-core,
  lib,
  pkgs,
  username,
  ...
}:

let
  casks = import ./casks.nix;
in
{
  system = {
    primaryUser = username;
    stateVersion = 7;
  };

  environment.shells = [ pkgs.zsh ];

  programs.zsh.enable = true;

  security.pam.services.sudo_local = {
    touchIdAuth = true;
    # Keep biometric sudo available inside the managed tmux sessions.
    reattach = true;
  };

  users.users.${username} = {
    home = homeDirectory;
  };

  nix.settings = {
    # nh's system-profile step runs nix under sudo, where the process-scoped
    # NIX_CONFIG from bootstrap does not reach; root falls back to
    # /etc/nix/nix.conf, so the managed file must carry the features itself.
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    require-sigs = true;
    substituters = lib.mkForce [ "https://cache.nixos.org/" ];
    trusted-public-keys = lib.mkForce [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    trusted-users = lib.mkForce [ "root" ];
  };

  nix.optimise.automatic = true;

  system.activationScripts.postActivation.text = lib.mkAfter ''
    shell_user=${lib.escapeShellArg username}
    shell_record="/Users/$shell_user"
    expected_shell=/run/current-system/sw/bin/zsh

    if ! /usr/bin/dscl . -read "$shell_record" UniqueID >/dev/null 2>&1; then
      echo "nix-darwin: primary user $shell_user does not exist; refusing to create it" >&2
      exit 1
    fi
    current_shell="$(/usr/bin/dscl . -read "$shell_record" UserShell 2>/dev/null \
      | /usr/bin/awk '{ print $2 }')"
    if [ "$current_shell" != "$expected_shell" ]; then
      /usr/bin/dscl . -create "$shell_record" UserShell "$expected_shell"
    fi
    current_shell="$(/usr/bin/dscl . -read "$shell_record" UserShell 2>/dev/null \
      | /usr/bin/awk '{ print $2 }')"
    if [ "$current_shell" != "$expected_shell" ]; then
      echo "nix-darwin: failed to configure the login shell for $shell_user" >&2
      exit 1
    fi
  '';

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
      "manaflow-ai/homebrew-cmux" = homebrew-cmux;
    };

    mutableTaps = false;
  };

  homebrew = {
    enable = true;
    taps = builtins.attrNames config.nix-homebrew.taps;

    inherit casks;

    global = {
      autoUpdate = false;
      brewfile = true;
    };

    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "check";
    };
  };
}
