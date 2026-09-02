{
  config,
  homeDirectory,
  homeModules,
  homebrew-cask,
  homebrew-core,
  lib,
  pkgs,
  username,
  ...
}:

let
  casks = import ./casks.nix;
  binaryCaches = import ../modules/binary-caches.nix;
in
{
  system = {
    primaryUser = username;
    stateVersion = 7;
  };
  # Keep the native macOS menu bar permanently visible now that SketchyBar
  # no longer occupies the top edge.
  system.defaults.NSGlobalDomain._HIHideMenuBar = false;

  environment.shells = [ pkgs.zsh ];

  # Native macOS applications resolve fonts through CoreText, not Home
  # Manager's fontconfig cache, so the Nerd Font is registered system-wide.
  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

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
    # Forced rather than merged: nix-darwin and its inputs may add substituters
    # of their own, and the reviewed boundary is an exact list, not a floor.
    substituters = lib.mkForce binaryCaches.substituters;
    trusted-public-keys = lib.mkForce binaryCaches.trusted-public-keys;
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
    # nix-darwin does not unload launch agents when their declaring module is
    # removed. Retire the window-management agents removed in #421.
    #
    # This script runs as root inside `> Activating configuration`, where
    # nothing it does is visible unless it says so. Everything below therefore
    # announces itself, and only when it actually acts: a converged machine
    # stays quiet, and a machine that just had its login shell rewritten from
    # under it says which shell and what it was before.
    user_uid="$(/usr/bin/id -u "$shell_user")"
    for retired_agent in org.nixos.sketchybar org.nixos.yabai org.nixos.skhd; do
      retired_plist="$shell_record/Library/LaunchAgents/$retired_agent.plist"
      if [ -e "$retired_plist" ]; then
        echo "atyrode: retiring launch agent $retired_agent, removing $retired_plist" >&2
      fi
      /bin/launchctl bootout "gui/$user_uid/$retired_agent" 2>/dev/null || true
      /bin/rm -f "$retired_plist"
    done

    # The writer that actually converges the login shell on this platform: it
    # holds root here, where `atyrode apply` would need a password. That is why
    # apply's own login-shell step reports "already" on a healthy Mac -- it is
    # verifying this, one step later, not doing it.
    current_shell="$(/usr/bin/dscl . -read "$shell_record" UserShell 2>/dev/null \
      | /usr/bin/awk '{ print $2 }')"
    if [ "$current_shell" != "$expected_shell" ]; then
      echo "atyrode: login shell for $shell_user: ''${current_shell:-unset} -> $expected_shell" >&2
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

    # Declarative removal semantics (operator decision 2026-08-27): anything
    # no longer declared is uninstalled and zapped during activation, so
    # retiring a cask removes it and its support files from the machine on
    # the next apply with no bespoke removal code. Zap is deliberately
    # data-destructive for undeclared casks; native state worth keeping must
    # be declared.
    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "zap";
    };
  };
}
