{
  config,
  host,
  hostId,
  homeModules,
  lib,
  machineDirectory,
  pkgs,
  ...
}:

let
  inherit (host) homeDirectory username;

  # Where the machine answers, read from its own directory under `fleet/`
  # because that is the only place in this public repository a machine states
  # its address; `fleet/machines/<host>/address.nix` says why.
  machineAddress = import (machineDirectory + "/address.nix");

  # Which public keys may open a session on this machine. The registry under
  # `modules/home/ssh/` is the fleet's reviewed key material, so a key reaches
  # a machine only through a reviewed commit. sshd here reads none of the
  # operator's home directory, so registration is access: every registered key
  # is declared below or cannot connect at all.
  registryFields =
    line:
    lib.filter (field: builtins.isString field && field != "") (builtins.split "[[:space:]]+" line);
  registryLines =
    file:
    lib.filter (line: line != "" && !lib.hasPrefix "#" line) (
      lib.splitString "\n" (builtins.readFile file)
    );
  reviewedKeys = map (fields: {
    inherit fields;
    name = builtins.elemAt fields 0;
    keytype = builtins.elemAt fields 1;
    key = builtins.elemAt fields 2;
  }) (map registryFields (registryLines ../home/ssh/fleet-keys));
  reviewedPublicKeys = map (entry: "${entry.keytype} ${entry.key} ${entry.name}") reviewedKeys;

  # Which public keys may run ONE command on this machine and nothing else
  # (`modules/home/ssh/deploy-keys`): rendered with a forced command and every
  # forwarding refused, so the automation holding the private half -- a GitHub
  # workflow, for the manifold deploy key -- can trigger that script and cannot
  # open a shell. Rows naming another host are not rendered here.
  deployKeys = map (fields: {
    inherit fields;
    name = builtins.elemAt fields 0;
    hostId = builtins.elemAt fields 1;
    keytype = builtins.elemAt fields 2;
    key = builtins.elemAt fields 3;
    command = builtins.elemAt fields 4;
  }) (map registryFields (registryLines ../home/ssh/deploy-keys));
  deployPublicKeys = map (
    entry:
    ''command="${entry.command}",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ${entry.keytype} ${entry.key} ${entry.name}''
  ) (lib.filter (entry: entry.hostId == hostId) deployKeys);
in
{
  assertions = [
    {
      assertion = host.activation == "nixos";
      message = "${hostId} must be owned by the nixos activation backend";
    }
    {
      assertion = host.hostname != null;
      message = "${hostId} must declare the hostname it answers to";
    }
    {
      assertion = builtins.elem "containers" host.capabilities;
      message = "${hostId} runs a container engine, so its registry entry must select the containers capability";
    }
    {
      assertion =
        reviewedKeys != [ ]
        && lib.all (
          entry: builtins.length entry.fields == 3 && lib.hasPrefix "ssh-ed25519" entry.keytype
        ) reviewedKeys;
      message = "${hostId} requires modules/home/ssh/fleet-keys to hold reviewed Ed25519 keys in the NAME KEYTYPE KEY shape";
    }
    {
      assertion = lib.all (
        entry:
        builtins.length entry.fields == 5
        && lib.hasPrefix "ssh-ed25519" entry.keytype
        && lib.hasPrefix "/" entry.command
      ) deployKeys;
      message = "${hostId} requires modules/home/ssh/deploy-keys rows in the NAME HOST KEYTYPE KEY COMMAND shape, with an absolute command";
    }
    {
      assertion =
        config.services.openssh.authorizedKeysFiles == [
          "/etc/ssh/authorized_keys.d/%u"
        ];
      message = "${hostId} accepts only root-owned declarative SSH key files";
    }
  ];

  nixpkgs.hostPlatform = host.system;
  system.autoUpgrade.enable = false;

  facter.reportPath = machineDirectory + "/facter.json";

  # How clan reaches the machine: its name, never its address. An address is
  # a fact that changes when the machine is rehosted, and clan's own default
  # for this option is the machine's fully qualified name for exactly that
  # reason -- with a name, moving the machine costs a DNS record and no
  # commit, and everything that addresses it keeps working. The account is
  # the operator's, not root: root has no password and no SSH login, and
  # activation escalates through sudo.
  clan.core.networking.targetHost = "${username}@${config.networking.fqdn}";

  networking = {
    hostName = host.hostname;
    inherit (machineAddress) domain;
    # The reviewed public-VPS exposure is TCP 22, and 80 + 443 for exactly the
    # vhosts manifold-dev-hub.nix and myparcelle-dev.nix declare. mkForce keeps this
    # authoritative over clan-core's recommended-defaults mDNS port (UDP
    # 5353), which must never listen on a public uplink.
    firewall = {
      enable = true;
      allowedTCPPorts = lib.mkForce [
        22
        80
        443
      ];
      allowedUDPPorts = lib.mkForce [ ];
    };
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    authorizedKeysCommand = "none";
    authorizedKeysInHomedir = false;
    # The install ceremony generates this machine-specific key in RAM, binds
    # its public fingerprint into the destructive plan, and installs only the
    # private half onto the new root. It never enters Git or the Nix store.
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      AllowUsers = [ username ];
      AuthenticationMethods = "publickey";
      HostbasedAuthentication = false;
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitEmptyPasswords = false;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;
      TrustedUserCAKeys = "none";
    };
  };

  users = {
    mutableUsers = false;
    users = {
      root.hashedPassword = "!";
      ${username} = {
        extraGroups = [ "wheel" ];
        hashedPassword = "!";
        home = homeDirectory;
        isNormalUser = true;
        openssh.authorizedKeys.keys = reviewedPublicKeys ++ deployPublicKeys;
        shell = pkgs.zsh;
        linger = true;
      };
    };
  };
  security.sudo.wheelNeedsPassword = false;
  programs.zsh.enable = true;

  # The host selects the `containers` capability. NixOS owns its operational
  # system boundary: a persistent rootless per-user engine, never rootful
  # Docker and never docker-group membership.
  virtualisation.docker.rootless = {
    enable = true;
    setSocketVariable = true;
  };

  # A file already at a path Home Manager now links -- the hand-placed
  # Cloudflare token the cloudflare-dns var replaces, for one -- is moved
  # aside as <name>.backup instead of failing the activation, as on the other
  # classes. The apply that first places a var must not stop halfway because
  # the machine had the value before the fleet did.
  home-manager.backupFileExtension = "backup";
  home-manager.users.${username} = {
    imports = homeModules;
    home = {
      inherit homeDirectory username;
    };
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Clan copies the closure before sudo activation. This personal-development
    # administrator is already root-equivalent through passwordless sudo; make
    # that same declared authority explicit at the Nix daemon boundary. Forced
    # so the daemon trusts exactly the set the registry declares, rather than
    # that set plus whatever a module default contributed.
    trusted-users = lib.mkForce host.nixTrustedUsers;
  };
  boot.zfs.forceImportRoot = false;
  system.stateVersion = "26.05";

  # A machine on a public uplink is never updated by a command that happened
  # to run: clan refuses to deploy it unless the operator names it.
  clan.core.deployment.requireExplicitUpdate = true;
}
