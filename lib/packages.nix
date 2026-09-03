# Reviewed package policy and the two pkgs constructors:
# repositoryPkgsFor (registry-aware overlay for this repository's targets)
# and evaluationPkgsFor (empty-registry overlay for portable evaluations).
{
  babel,
  clan-core,
  lib,
  nixpkgs,
  self,
  targets,
}:

let
  inherit (targets)
    capabilitySummary
    publicBootstrapProfile
    publicHost
    rawBootstrapProfiles
    rawHosts
    validateBootstrapProfileRegistry
    validateHostRegistry
    ;

  # Each name corresponds to a reviewed package in a selected capability.
  # Homebrew casks are governed independently by the nix-darwin module.
  allowedUnfreePackages = [
    "arduino-ide"
    "chatgpt"
    "claude-code"
    "obsidian"
    "nvidia-x11"
    "orbstack"
    "parsec-bin"
    "postman"
    "reaper"
    "spotify"
    "steam"
    "steam-original"
    "steam-unwrapped"
    "steamcmd"
    "vital"
  ];
  homebrewCasks = import ../modules/darwin/casks.nix;
  windowsPackageInventory = import ../fleet/windows-packages.nix;
  # Curated software the operator launches ephemerally; fleet/catalog.nix says
  # why nothing in it is declared.
  catalogEntries = import ../fleet/catalog.nix;

  repositoryPackageNames = [
    "atyrode"
    "atyrode-tui"
    "code"
    "codex"
    "atyrode-codex-seed"
    "omp"
    "omp-agents"
    "omp-configured"
    "atyrode-omp-seed"
    "manifold-agent"
  ];

  # Packages this repository neither builds under pkgs/ nor takes from
  # nixpkgs: they come from a pinned flake input. The inventory records them
  # as such rather than claiming nixpkgs provides them.
  flakeInputPackageNames = [
    "babel"
    "clan-cli"
  ];

  inventoryRevision = self.rev or self.dirtyRev or "dirty";

  mkPackageOverlay =
    {
      hostRegistry ? { },
      runtimeProfiles ? { },
    }:
    let
      publicRegistry = lib.mapAttrs publicHost (validateHostRegistry hostRegistry);
      publicRuntimeProfiles = lib.mapAttrs publicBootstrapProfile (
        validateBootstrapProfileRegistry runtimeProfiles
      );
    in
    lib.composeManyExtensions [
      (final: _previous: {
        atyrode-tui = final.callPackage ../pkgs/atyrode-tui { };
        # Repository-owned on every platform: upstream releases outpace
        # nixpkgs, which also cannot build codex on aarch64-darwin.
        code = final.callPackage ../pkgs/code { };
        codex = final.callPackage ../pkgs/codex { };
        codex-seed = final.callPackage ../pkgs/codex-seed { };
        omp = final.callPackage ../pkgs/omp { };
        omp-agents = final.callPackage ../pkgs/omp-agents { };
        omp-configured = final.callPackage ../pkgs/omp-configured { };
        omp-seed = final.callPackage ../pkgs/omp-seed { };
        # Fleet agent for the self-hosted manifold hub (#418), pinned as a
        # release asset (atyrode/manifold#52): the upstream flake's bun-deps
        # FOD is not reproducible across machines (atyrode/manifold#51).
        # fleet/manifold.json supportedSystems gates consumers to the
        # published asset platforms.
        manifold-agent = final.callPackage ../pkgs/manifold-agent { };
        # Archival instrument for this machine's agent session history. The
        # right-hand `babel` is the flake input from the enclosing scope: this
        # attribute set is not recursive, so there is no self-reference here.
        babel = babel.packages.${final.stdenv.hostPlatform.system}.default;
        # The fleet CLI, from the same clan-core revision that builds the
        # machines, so `clan secrets` and `clan vars` on the operator's
        # machine speak the layout the machines evaluate.
        clan-cli = clan-core.packages.${final.stdenv.hostPlatform.system}.clan-cli;
        atyrode = final.callPackage ../pkgs/atyrode {
          capabilities = capabilitySummary;
          catalog = catalogEntries;
          inherit homebrewCasks;
          hostRegistry = publicRegistry // publicRuntimeProfiles;
          revision = inventoryRevision;
          windowsPackages = windowsPackageInventory;
        };
      })
      (
        _final: previous:
        lib.optionalAttrs previous.stdenv.hostPlatform.isDarwin {
          # nixpkgs Darwin fixup replaces Obsidian's Developer ID signature
          # with an ad-hoc one. The pinned upstream DMG and derivation audit
          # in #89 verified that skipping fixup preserves its signed bundle.
          obsidian = previous.obsidian.overrideAttrs (_: {
            dontFixup = true;
          });
          # Prism Launcher 11.0.3 bundles executable framework symlinks.
          # The generic Qt hook scans every one and crashes Bash on Darwin,
          # so wrap only the app's actual launcher.
          prismlauncher = previous.prismlauncher.overrideAttrs (previousAttrs: {
            dontWrapQtApps = true;
            buildCommand = previousAttrs.buildCommand + ''
              launcher="$out/Applications/PrismLauncher.app/Contents/MacOS/prismlauncher"
              target="$(readlink -e "$launcher")"
              rm "$launcher"
              makeQtWrapper "$target" "$launcher"
            '';
          });
          # nixpkgs Darwin fixup replaces Spotify's Developer ID signature
          # with an ad-hoc one, breaking macOS privacy identity (TN3179).
          # The focused test in #89 validated that skipping fixup preserves it.
          spotify = previous.spotify.overrideAttrs (_: {
            dontFixup = true;
          });
          # nixpkgs Darwin fixup likewise replaces VLC's verified upstream
          # Developer ID signature even though the derivation only repacks
          # the app bundle and creates a wrapper outside it (#89).
          vlc-bin = previous.vlc-bin.overrideAttrs (_: {
            dontFixup = true;
          });
        }
      )
    ];

  agentToolsOverlay = mkPackageOverlay {
    hostRegistry = rawHosts;
    runtimeProfiles = rawBootstrapProfiles;
  };

  # Registry-aware pkgs for this repository's own targets and checks.
  repositoryPkgsFor =
    system:
    import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = package: builtins.elem (lib.getName package) allowedUnfreePackages;
      overlays = [ agentToolsOverlay ];
    };

  # Empty-registry pkgs for portable/server evaluations that must not see
  # this repository's fixed host identities.
  evaluationPkgsFor =
    system:
    import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = package: builtins.elem (lib.getName package) allowedUnfreePackages;
      overlays = [ (mkPackageOverlay { }) ];
    };
in
{
  inherit
    agentToolsOverlay
    allowedUnfreePackages
    evaluationPkgsFor
    flakeInputPackageNames
    homebrewCasks
    inventoryRevision
    mkPackageOverlay
    repositoryPackageNames
    repositoryPkgsFor
    windowsPackageInventory
    ;
}
