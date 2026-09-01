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
    canonicalNixosWslConfigs
    darwinHosts
    inventoryBySystem
    mkPortableHomeConfiguration
    mkServerHomeConfig
    serverHomeConfigs
    serverProfileManifests
    ;

  isLinux = lib.hasSuffix "-linux" system;
  hostBudgets = (lib.importJSON ../inventory/host-budgets.json).budgets;
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
  systemDoctorAtyrode = pkgs.atyrode.override {
    enableTestHooks = true;
    atyrode-tui = cockpitStub;
    atyrodeTuiPackage = pkgs.atyrode-tui;
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
  registryCheck =
    pkgs.runCommand "check-host-registry-${system}"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        jq -e '
          length >= 7
          and all(.[];
            (.id | type == "string")
            and (.identityMode | IN("fixed", "runtime"))
            and (.activation | IN("home-manager", "nix-darwin", "nixos-wsl"))
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
        if ! diff ${pkgs.writeText "hosts-expected.tsv" hostsTsv} ${../inventory/hosts.tsv}; then
          echo 'inventory/hosts.tsv is out of date with hosts/default.nix and hosts/bootstrap.nix' >&2
          exit 1
        fi
        mkdir "$out"
      '';
  ciInventory = builtins.fromJSON (builtins.readFile ../inventory/ci.json);

  # The registry imports the shared CI constants (also read by
  # scripts/docs-drift-guard.sh and mirrored by the static matrix in
  # .github/workflows/nix.yml) so a drifting inventory/ci.json fails
  # evaluation instead of silently desynchronizing.
  checksForSystem = {
    omp-auth-broker = import ./omp-auth-broker.nix { inherit lib pkgs; };
    omp-stack = import ./omp-stack.nix { inherit lib pkgs; };
    omp-wrapper = import ./omp-wrapper.nix { inherit lib pkgs; };
    omp-agent-references = import ./omp-agent-references.nix { inherit lib pkgs; };
    agent-tools-terminal-viewing = import ./agent-terminal-viewing.nix { inherit pkgs; };
    classifier-schedule = import ./classifier-schedule.nix { inherit lib pkgs; };
    babel-archive = import ./babel-archive.nix { inherit lib pkgs; };
  }
  // {
    atyrode-apply = import ./atyrode-apply.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
      productionAtyrode = pkgs.atyrode;
      productionHost =
        {
          "aarch64-darwin" = "alex-aarch64-darwin";
          "aarch64-linux" = "alex-aarch64-linux";
          "x86_64-linux" = "alex-x86_64-linux";
        }
        .${system};
    };
    atyrode-lifecycle = import ./atyrode-lifecycle.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    atyrode-runtime = import ./atyrode-runtime.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    atyrode-tunnel = import ./atyrode-tunnel.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    atyrode-credentials = import ./atyrode-credentials.nix {
      inherit pkgs;
      atyrode = systemDoctorAtyrode;
    };
    bootstrap = import ./bootstrap.nix { inherit pkgs; };
    codex-seed = import ./codex-seed.nix { inherit pkgs; };
    desktop-fonts = import ./desktop-fonts.nix {
      inherit lib pkgs;
      hostConfigs = canonicalHomeConfigs;
    };
    get-entrypoint = import ./get-sh.nix { inherit pkgs; };
    omp-seed = import ./omp-seed.nix { inherit pkgs; };
    omp-secret-obfuscation = import ./omp-secret-obfuscation.nix { inherit pkgs; };
    omp-isolated-writer = import ./omp-isolated-writer.nix { inherit pkgs; };
    home-evaluation = homeEvaluation;
    host-registry = registryCheck;
    package-ownership = import ./package-ownership.nix {
      inherit pkgs;
      inventory = inventoryBySystem.${system};
    };
    shell-surface = import ./shell-surface.nix {
      inherit lib pkgs;
      hostConfigs = canonicalHomeConfigs;
    };
    system-boundary = import ./system-boundary.nix {
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
    # docs-links and production-facts scan the whole tree (docs
    # included); they are the two intentional exceptions the docs-only
    # fast path builds directly and scripts/docs-drift-guard.sh excludes.
    docs-links = import ./docs-links.nix { inherit lib pkgs; };
    docs-drift-guard = import ./docs-drift-guard.nix { inherit pkgs; };
    classify-ci-paths = import ./classify-ci-paths.nix { inherit pkgs; };
    production-facts = import ./production-facts.nix { inherit pkgs; };
    darwin-activation = import ./darwin-activation.nix {
      inherit lib pkgs;
      darwinConfigs = canonicalDarwinConfigs;
    };
    treefmt = treefmtCheck;
    omp-managed-keys = import ./omp-managed-keys.nix {
      inherit lib pkgs;
      ompConfigured = pkgs.omp-configured;
    };

    # windows is neither a lint nor source-pure: it stubs wsl.exe and
    # winget.exe and drives pwsh, which makes it the heaviest check in the
    # registry. It sits on this leg because its subject host,
    # alex-x86_64-linux-wsl, only exists on x86_64-linux.
    windows = import ./windows.nix {
      inherit lib pkgs;
      nixosConfig = canonicalNixosWslConfigs.alex-x86_64-linux-wsl;
      windowsPackages = windowsPackageInventory;
    };
  }
  // lib.optionalAttrs isLinux {
    # The resource guard evaluates the Linux module branch (earlyoom is a
    # Linux-only package), so it exists on Linux systems only.
    resource-guard = import ./agent-resource-guard.nix { inherit lib pkgs; };
    manifold-node = import ./manifold-node.nix {
      inherit lib pkgs system;
      serverConfig = serverHomeConfig.config;
    };
    portable-profile-contract = import ./portable-profile-contract.nix {
      inherit lib mkPortableHomeConfiguration pkgs;
      profileName = "development-${system}";
      fixedHomeConfig =
        canonicalHomeConfigs.${
          {
            "aarch64-linux" = "alex-aarch64-linux";
            "x86_64-linux" = "alex-x86_64-linux";
          }
          .${system}
        };
    };
    portable-profiles = import ./portable-profiles.nix {
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
    host-closure = import ./host-closure.nix {
      inherit lib pkgs system;
      budgets = hostBudgets;
      hostConfigs = systemHomeConfigs;
    };
  }
  // lib.optionalAttrs (lib.hasSuffix "-darwin" system) (
    {
      darwin-evaluation = darwinEvaluation;
    }
    // import ./app-signatures.nix {
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
  "inventory/ci.json systems must cover ${system}";
assert lib.assertMsg (
  system != "x86_64-linux"
  || lib.all (name: builtins.hasAttr name checksForSystem) ciInventory.docsOnlyChecks
) "inventory/ci.json docsOnlyChecks must name existing x86_64-linux checks";
checksForSystem
