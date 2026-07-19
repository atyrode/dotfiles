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
  temporaryBuilderStateDir = "/var/lib/atyrode/temporary-builder";
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

  # Temporary bootstrap bridge: keep the hardened guest-side SSH policy
  # reproducible without committing a key, source address, or fleet topology.
  # The service starts only after the operator enrolls the machine-local key.
  services.openssh = {
    enable = true;
    openFirewall = true;
    authorizedKeysFiles = lib.mkForce [ "${temporaryBuilderStateDir}/authorized_keys/%u" ];
    settings = {
      AllowUsers = [ username ];
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  systemd.services.sshd.unitConfig.ConditionPathExists =
    "${temporaryBuilderStateDir}/authorized_keys/${username}";
  systemd.tmpfiles.rules = [
    "d ${temporaryBuilderStateDir} 0755 root root -"
    "d ${temporaryBuilderStateDir}/authorized_keys 0755 root root -"
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
