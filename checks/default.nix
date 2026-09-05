# Per-system check registry and fixture assembly. Platform gating:
# x86_64-linux carries the whole-tree lints and the Windows/WSL contract,
# Linux carries the portable/server contracts, Darwin carries the evaluation
# and signature checks.
{
  self,
  lib,
  nixpkgs,
  system,
  pkgs,
  targets,
  packages,
  configurations,
  treefmtCheck,
}:

let
  inherit (targets)
    hosts
    hostsTsv
    publicTargets
    selectHomeManagerProfiles
    serverPolicy
    targetRegistryJson
    ;
  inherit (packages) windowsPackageInventory;
  inherit (configurations)
    canonicalDarwinConfigs
    canonicalHomeConfigs
    canonicalNixosConfigs
    clan
    darwinHosts
    inventoryBySystem
    mkPortableHomeConfiguration
    mkServerHomeConfig
    serverHomeConfigs
    serverProfileManifests
    ;

  isLinux = lib.hasSuffix "-linux" system;
  hostBudgets = (lib.importJSON ../fleet/host-budgets.json).budgets;
  serverHomeConfig = if isLinux then serverHomeConfigs.${system} else null;
  alternateServerHomeConfig =
    if isLinux then
      mkServerHomeConfig {
        inherit system;
        homeDirectory = "/home/second-fixture";
        username = "second-fixture";
      }
    else
      null;
  externalServerFixture =
    if isLinux then
      import ./fixtures/nixos-server.nix {
        dotfiles = self;
        inherit nixpkgs system;
      }
    else
      null;
  cockpitStub = pkgs.writeShellScriptBin "atyrode-tui" ''
    printf 'cockpit:%s:%s\n' "$ATYRODE_CLI" "$#"
  '';
  # The committed sops tree registers this development machine and the
  # recovery recipient alone, so the registered state of the operator probe
  # on any fixture host is unreachable through it. The check CLI reads this
  # tree instead: every fixture device registered with the recipient its
  # stubbed generator mints, in exactly the shape `clan secrets users add`
  # and `clan secrets groups add-user` write -- a key.json per user and a
  # relative symlink per group member.
  fixtureDeviceRecipient = "age1fixturedevice00000000000000000000000000000000000000000000000";
  fixtureEnclaveRecipient = "age1se1fixtureoperator00000000000000000000000000000000000000000000";
  fixtureSopsDirectory =
    pkgs.runCommand "fixture-sops"
      {
        users = builtins.toJSON {
          alex-fixture-nixos = fixtureDeviceRecipient;
          alex-wsl = fixtureDeviceRecipient;
          alex-macbook = fixtureEnclaveRecipient;
          alex-recovery = "age1pjcf90jv97whw39dxtynv99rwgdj4u7nuy7m3a4fvhgfrsrgvsespknzgm";
        };
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p "$out/groups/admins/users"
        jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$users" | while read -r user recipient; do
          mkdir -p "$out/users/$user"
          jq -n --arg recipient "$recipient" '[{publickey: $recipient, type: "age"}]' \
            > "$out/users/$user/key.json"
          ln -s "../../../users/$user" "$out/groups/admins/users/$user"
        done
      '';
  systemDoctorAtyrode = pkgs.atyrode.override {
    enableTestHooks = true;
    atyrode-tui = cockpitStub;
    atyrodeTuiPackage = pkgs.atyrode-tui;
    sopsDirectory = fixtureSopsDirectory;
    hostRegistry = publicTargets // {
      fixture-nixos = {
        id = "fixture-nixos";
        activation = "nixos";
        capabilities = [
          "base"
          "development"
          "containers"
        ];
        dotfilesDirectory = "/home/fixture/nix-dotfiles";
        homeDirectory = "/home/fixture";
        hostname = null;
        nixTrustedUsers = [
          "root"
          "fixture"
        ];
        platform = "linux";
        system = "x86_64-linux";
        username = "fixture";
      };
      fixture-security = {
        id = "fixture-security";
        activation = "home-manager";
        capabilities = [
          "base"
          "security"
        ];
        dotfilesDirectory = "/home/fixture/nix-dotfiles";
        homeDirectory = "/home/fixture";
        hostname = null;
        platform = "linux";
        system = "x86_64-linux";
        username = "fixture";
      };
      # No registered Linux host carries the desktop stack any more, and the
      # system diagnostics for a Linux desktop (device rules, container
      # engine, antivirus) are a contract of the CLI, not of a machine.
      fixture-desktop = {
        id = "fixture-desktop";
        activation = "home-manager";
        capabilities = [
          "base"
          "development"
          "agent-tools"
          "security"
          "desktop"
          "mobile"
          "media"
          "containers"
        ];
        description = "Portable x86_64 Linux desktop fixture";
        identityMode = "runtime";
        platform = "linux";
        system = "x86_64-linux";
      };
    };
  };
  systemHomeConfigs = lib.filterAttrs (
    name: _config: hosts.${name}.system == system
  ) canonicalHomeConfigs;
  systemDarwinConfigs = lib.filterAttrs (
    name: _config: darwinHosts.${name}.system == system
  ) canonicalDarwinConfigs;
  homeEvaluationPaths = lib.mapAttrsToList (
    _name: config: config.activationPackage.drvPath
  ) systemHomeConfigs;
  darwinEvaluationPaths = lib.mapAttrsToList (
    _name: config: config.system.drvPath
  ) systemDarwinConfigs;
  homeEvaluation = builtins.deepSeq homeEvaluationPaths (
    pkgs.runCommand "check-home-evaluation-${system}" { } ''
      mkdir "$out"
    ''
  );
  darwinEvaluation = builtins.deepSeq darwinEvaluationPaths (
    pkgs.runCommand "check-darwin-evaluation-${system}" { } ''
      mkdir "$out"
    ''
  );
  registryFile = pkgs.writeText "atyrode-target-registry.json" targetRegistryJson;
  # The clan machines are exactly the registry's hosts, one class each: a
  # host clan builds that the registry does not name, or the reverse, is a
  # second place a machine is named.
  expectedClanMachines = lib.mapAttrs (
    _name: host: if host.activation == "nix-darwin" then "darwin" else "nixos"
  ) hosts;
  actualClanMachines = lib.mapAttrs (
    _name: machine: machine.machineClass
  ) clan.config.inventory.machines;
  clanMachineConfigs = lib.mapAttrs (_name: config: config.config) (
    canonicalDarwinConfigs // canonicalNixosConfigs
  );
  # Every clan machine decrypts with the key `atyrode apply` places
  # (pkgs/atyrode/lib/apply.sh names the same path), every value is encrypted
  # to the admins group, and the declared generators are exactly the fleet's:
  # a new one is a reviewed change, not a side effect. The fleet-wide four are
  # on every machine; the VPS -- the one machine whose registry activation is
  # plain `nixos` -- also holds the Cloudflare DNS token
  # (modules/nixos/cloudflare-dns.nix), and no other machine may.
  fleetGenerators = [
    "babel-archive"
    "babel-custody"
    "git-identity"
    "omp-auth-broker"
  ];
  expectedGenerators =
    name:
    lib.sort builtins.lessThan (
      fleetGenerators ++ lib.optional (hosts.${name}.activation == "nixos") "cloudflare-dns"
    );
  clanMachineSecretsAgree = lib.all (
    name:
    let
      config = clanMachineConfigs.${name};
    in
    config.sops.age.keyFile == "/var/lib/sops-nix/key.txt"
    && config.clan.core.sops.defaultGroups == [ "admins" ]
    && lib.attrNames config.clan.core.vars.generators == expectedGenerators name
  ) (lib.attrNames clanMachineConfigs);
  registryCheck =
    assert lib.assertMsg (
      actualClanMachines == expectedClanMachines
    ) "clan's inventory must name exactly the nix-darwin and NixOS hosts of fleet/hosts.nix, by class";
    assert lib.assertMsg clanMachineSecretsAgree
      "every clan machine must read /var/lib/sops-nix/key.txt, encrypt to the admins group, and declare exactly the babel, git-identity, and omp-auth-broker generators -- plus cloudflare-dns on the VPS alone";
    pkgs.runCommand "check-host-registry-${system}"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq -e '
          length >= 5
          and all(.[];
            (.id | type == "string")
            and (.identityMode | IN("fixed", "runtime"))
            and (.activation | IN("home-manager", "nix-darwin", "nixos", "nixos-wsl"))
            and (.system | type == "string")
            and (.description | type == "string" and length > 0)
            and (.capabilities | length > 0)
            and (
              if .identityMode == "runtime" then
                .activation == "home-manager"
                and .platform == "linux"
                and (has("username") | not)
                and (has("homeDirectory") | not)
              else
                (.username | type == "string")
                and (.homeDirectory | startswith("/"))
              end
            ))
          and ([.[].capabilities[]] | index("server") | not)
        ' ${registryFile} >/dev/null
        if ! diff ${pkgs.writeText "hosts-expected.tsv" hostsTsv} ${../fleet/hosts.tsv}; then
          echo 'fleet/hosts.tsv is out of date with fleet/hosts.nix and fleet/bootstrap-profiles.nix' >&2
          exit 1
        fi
        # The recovery recipient is registered and in the group from day one,
        # so the tree has a break-glass reader before the first value exists;
        # every device and machine registers through its ceremony.
        jq -e 'any(.[]; .publickey | startswith("age1"))' ${../sops/users/alex-recovery/key.json} >/dev/null ||
          { echo 'sops/users/alex-recovery/key.json must register the recovery recipient' >&2; exit 1; }
        test -e ${../sops}/groups/admins/users/alex-recovery/key.json ||
          { echo 'sops/groups/admins must hold the recovery recipient' >&2; exit 1; }
        mkdir "$out"
      '';
  ciInventory = builtins.fromJSON (builtins.readFile ../ci/ci.json);

  # The registry imports the shared CI constants (also read by
  # ci/docs-drift-guard.sh and mirrored by the static matrix in
  # .github/workflows/nix.yml) so a drifting ci/ci.json fails
  # evaluation instead of silently desynchronizing.
  checksForSystem = {
    omp-auth-broker = import ./omp/omp-auth-broker.nix { inherit lib pkgs; };
    omp-stack = import ./omp/omp-stack.nix { inherit lib pkgs; };
    omp-wrapper = import ./omp/omp-wrapper.nix { inherit lib pkgs; };
    omp-agent-references = import ./omp/omp-agent-references.nix { inherit lib pkgs; };
    agent-tools-terminal-viewing = import ./atyrode/agent-terminal-viewing.nix { inherit pkgs; };
    classifier-schedule = import ./lints/classifier-schedule.nix { inherit lib pkgs; };
    babel-archive = import ./atyrode/babel-archive.nix { inherit lib pkgs; };
  }
  // {
    manifold-node = import ./atyrode/manifold-node.nix {
      inherit
        hosts
        lib
        pkgs
        system
        ;
      serverConfig = if isLinux then serverHomeConfig.config else null;
      nixosConfigs = canonicalNixosConfigs;
      darwinConfigs = canonicalDarwinConfigs;
    };
    atyrode-apply = import ./atyrode/atyrode-apply.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
      productionAtyrode = pkgs.atyrode;
      # No aarch64-linux host is registered; dev-01 stands in there, and the
      # refusal then also covers the system mismatch.
      productionHost = if system == "aarch64-darwin" then "macbook" else "dev-01";
    };
    atyrode-lifecycle = import ./atyrode/atyrode-lifecycle.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    atyrode-runtime = import ./atyrode/atyrode-runtime.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    atyrode-credentials = import ./atyrode/atyrode-credentials.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    bootstrap-core = import ./atyrode/bootstrap/core.nix { inherit pkgs; };
    bootstrap-darwin-codes-recover = import ./atyrode/bootstrap/darwin-codes-recover.nix {
      inherit pkgs;
    };
    bootstrap-darwin-etc = import ./atyrode/bootstrap/darwin-etc.nix { inherit pkgs; };
    bootstrap-darwin-trust = import ./atyrode/bootstrap/darwin-trust.nix { inherit pkgs; };
    bootstrap-darwin-volumes = import ./atyrode/bootstrap/darwin-volumes.nix { inherit pkgs; };
    bootstrap-lint = import ./atyrode/bootstrap/lint.nix { inherit pkgs; };
    bootstrap-terminal = import ./atyrode/bootstrap/terminal.nix { inherit pkgs; };
    catalog = import ./fleet/catalog.nix {
      inherit lib nixpkgs pkgs;
      hostConfigs = canonicalHomeConfigs;
    };
    codex-seed = import ./omp/codex-seed.nix { inherit pkgs; };
    desktop-fonts = import ./fleet/desktop-fonts.nix {
      inherit lib pkgs;
      hostConfigs = canonicalHomeConfigs;
    };
    git-identity = import ./fleet/git-identity.nix {
      inherit lib pkgs system;
      clanConfigs = lib.mapAttrs (_name: machine: machine.config) (
        canonicalDarwinConfigs // canonicalNixosConfigs
      );
    };
    get-entrypoint = import ./atyrode/get-sh.nix { inherit pkgs; };
    omp-seed = import ./omp/omp-seed.nix { inherit pkgs; };
    omp-secret-obfuscation = import ./omp/omp-secret-obfuscation.nix { inherit pkgs; };
    omp-isolated-writer = import ./omp/omp-isolated-writer.nix { inherit pkgs; };
    home-evaluation = homeEvaluation;
    host-registry = registryCheck;
    package-ownership = import ./fleet/package-ownership.nix {
      inherit pkgs;
      inventory = inventoryBySystem.${system};
    };
    shell-surface = import ./fleet/shell-surface.nix {
      inherit lib pkgs;
      hostConfigs = canonicalHomeConfigs;
    };
    system-boundary = import ./fleet/system-boundary.nix {
      inherit lib pkgs system;
      inventory = inventoryBySystem.${system};
      homeConfigs = systemHomeConfigs;
      serverConfig = if isLinux then serverHomeConfig.config else null;
      externalFixture = if isLinux then externalServerFixture else null;
      darwinConfigs = systemDarwinConfigs;
    };
  }
  // lib.optionalAttrs (system == "x86_64-linux") {
    # Two unrelated reasons land checks on this one leg.
    #
    # Platform-independent lints: their output is a pure function of the
    # source tree, so emitting them on every system just re-runs the same
    # work three times in CI. Keep them on one leg only (#169).
    # docs-links, production-facts, and secret-shapes scan the whole tree
    # (docs included); they are the intentional exceptions the docs-only
    # fast path builds directly and ci/docs-drift-guard.sh excludes.
    docs-links = import ./lints/docs-links.nix { inherit lib pkgs; };
    docs-drift-guard = import ./lints/docs-drift-guard.nix { inherit pkgs; };
    classify-ci-paths = import ./lints/classify-ci-paths.nix { inherit pkgs; };
    macos-bash = import ./lints/macos-bash.nix { inherit pkgs; };
    production-facts = import ./lints/production-facts.nix { inherit pkgs; };
    secret-shapes = import ./lints/secret-shapes.nix { inherit lib pkgs; };
    git-hooks = import ./lints/git-hooks.nix { inherit lib pkgs; };
    darwin-activation = import ./fleet/darwin-activation.nix {
      inherit lib pkgs;
      darwinConfigs = canonicalDarwinConfigs;
    };
    treefmt = treefmtCheck;
    omp-managed-keys = import ./omp/omp-managed-keys.nix {
      inherit lib pkgs;
      ompConfigured = pkgs.omp-configured;
    };

    # windows is neither a lint nor source-pure: it stubs wsl.exe and
    # winget.exe and drives pwsh, which makes it the heaviest check in the
    # registry. It sits on this leg because its subject host,
    # wsl, only exists on x86_64-linux.
    windows = import ./fleet/windows.nix {
      inherit lib pkgs;
      nixosConfig = canonicalNixosConfigs.wsl;
      windowsPackages = windowsPackageInventory;
    };
  }
  // lib.optionalAttrs isLinux {
    # The resource guard evaluates the Linux module branch (earlyoom is a
    # Linux-only package), so it exists on Linux systems only.
    resource-guard = import ./atyrode/agent-resource-guard.nix { inherit lib pkgs; };
    portable-profile-contract = import ./fleet/portable-profile-contract.nix {
      inherit lib mkPortableHomeConfiguration pkgs;
      profileName = "development-${system}";
      # No aarch64-linux host is registered, so the Linux fixed host stands
      # in for both Linux legs; the assertions only read its evaluated config.
      fixedHomeConfig = canonicalHomeConfigs.dev-01;
    };
    portable-profiles = import ./fleet/portable-profiles.nix {
      inherit
        alternateServerHomeConfig
        lib
        pkgs
        selectHomeManagerProfiles
        serverHomeConfig
        serverPolicy
        system
        ;
      externalFixture = externalServerFixture;
      serverProfileManifest = serverProfileManifests.${system};
    };
    server-profile = serverProfileManifests.${system};
    host-closure = import ./fleet/host-closure.nix {
      inherit lib pkgs system;
      budgets = hostBudgets;
      hostConfigs = systemHomeConfigs;
    };
  }
  // lib.optionalAttrs (lib.hasSuffix "-darwin" system) (
    {
      darwin-evaluation = darwinEvaluation;
    }
    // import ./fleet/app-signatures.nix {
      inherit pkgs;
      apps = [
        {
          name = "obsidian-signature";
          app = "Obsidian";
          bundleId = "md.obsidian";
          teamId = "6JSW4SJWN9";
          package = pkgs.obsidian;
        }
        {
          name = "spotify-signature";
          app = "Spotify";
          bundleId = "com.spotify.client";
          teamId = "2FNC3A47ZF";
          package = pkgs.spotify;
        }
        {
          name = "vlc-signature";
          app = "VLC";
          bundleId = "org.videolan.vlc";
          teamId = "75GAHG3SZQ";
          package = pkgs.vlc-bin;
        }
      ];
    }
  );
in
assert lib.assertMsg (builtins.elem system ciInventory.systems)
  "ci/ci.json systems must cover ${system}";
assert lib.assertMsg (
  system != "x86_64-linux"
  || lib.all (name: builtins.hasAttr name checksForSystem) ciInventory.docsOnlyChecks
) "ci/ci.json docsOnlyChecks must name existing x86_64-linux checks";
checksForSystem
