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
  binaryCaches = import ../modules/binary-caches.nix;
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

  # SSH access for remote management of the WSL instance.
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

  atyrode.dotfiles.hostRegistry = hostRegistry;
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
