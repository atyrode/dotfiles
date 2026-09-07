{
  config,
  host,
  hostId,
  homeModules,
  lib,
  overlayDomain,
  pkgs,
  ...
}:

let
  inherit (host) username;
  binaryCaches = import ../shared/binary-caches.nix;
  # Windows-started sessions already carry this PATH. Systemd-started shells
  # do not; ask Windows for it instead of retaining another session's socket
  # or guessing the Windows user's App Execution Alias directory.
  windowsPath = "${pkgs.atyrode}/libexec/atyrode-wsl-path";
  windowsEnvironment = ''
    if [ -z "''${WSLPATH:-}" ]; then
      if _atyrode_windows_path="$(${windowsPath} --automount-root ${lib.escapeShellArg config.wsl.wslConf.automount.root} 2>/dev/null)"; then
        export WSLPATH="$_atyrode_windows_path"
        export PATH="$PATH:$WSLPATH"
      fi
      unset _atyrode_windows_path
    fi
  '';
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

  # The upstream wrapper sources set-environment, while interactive shells
  # can inherit its already-initialized marker from a user service. Cover
  # both entry points and leave split-path to maintain upstream WSLPATH.
  environment.extraInit = lib.mkBefore windowsEnvironment;
  environment.interactiveShellInit = windowsEnvironment;

  networking.hostName = host.hostname;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The same two caches nix-darwin declares, so a WSL apply downloads the
    # closure CI built instead of rebuilding it on the Windows machine. Forced
    # because the NixOS module and NixOS-WSL each contribute the official
    # entries as well, and merging would list them twice; doctor asserts the
    # exact reviewed list.
    substituters = lib.mkForce binaryCaches.substituters;
    trusted-public-keys = lib.mkForce binaryCaches.trusted-public-keys;
  };

  # Local CUDA runtime capabilities run in Docker. NVIDIA is supplied by
  # Windows through WSL and exposed to containers through CDI; model data and
  # containers remain machine-local and are never created by activation.
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
  };
  hardware.nvidia-container-toolkit = {
    enable = true;
    discovery-mode = "wsl";
    suppressNvidiaDriverAssertion = true;

    # The WSL generator discovers the matching Windows driver files. Avoid
    # appending an unrelated Linux NVIDIA driver closure to the CDI spec.
    mounts = lib.mkForce [ ];
    mount-nvidia-executables = false;
    mount-nvidia-docker-1-directories = false;
  };
  systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig.Environment =
    "LD_LIBRARY_PATH=/usr/lib/wsl/lib";

  programs.zsh.enable = true;

  # Reached only over the overlay: a WSL guest has no address of its own that
  # the fleet could name, and the Windows side forwards nothing in. sshd
  # exists for `atyrode fleet apply wsl` from the workshop and for the
  # operator's own devices, so it answers the operator's key and nothing
  # else; the overlay is what stands between it and the internet.
  clan.core.networking.targetHost = "${username}@${host.hostname}.${overlayDomain}";
  services.openssh = {
    enable = true;
    startWhenNeeded = true;
    settings.PasswordAuthentication = false;
  };

  users.users.${username} = {
    shell = pkgs.zsh;
    extraGroups = [ "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG2gDla8zu6J8xeBsssLwx5BL3AyduQtkNeMYV4MjbS"
    ];
  };

  home-manager = {
    backupFileExtension = "backup";
    users.${username} = {
      imports = homeModules;
      home = {
        inherit username;
        inherit (host) homeDirectory;
      };
      systemd.user.services.atyrode-local-qwen-idle-reaper = {
        Unit.Description = "Stop an unused local Qwen runtime after its session grace period";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.atyrode} runtime reap local-qwen";
        };
      };
      systemd.user.timers.atyrode-local-qwen-idle-reaper = {
        Unit.Description = "Check local Qwen session leases and API activity";
        Timer = {
          OnBootSec = "1m";
          OnUnitActiveSec = "1m";
          AccuracySec = "5s";
        };
        Install.WantedBy = [ "timers.target" ];
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
