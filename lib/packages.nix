# Reviewed package policy and the two pkgs constructors:
# repositoryPkgsFor (registry-aware overlay for this repository's targets)
# and evaluationPkgsFor (empty-registry overlay for portable evaluations).
{
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
    "signal-desktop"
    "spotify"
    "steam"
    "steam-original"
    "steam-unwrapped"
    "steamcmd"
    "vital"
  ];
  homebrewCasks = import ../darwin/casks.nix;
  windowsPackageInventory = import ../windows/packages.nix;

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
        # inventory/manifold.json supportedSystems gates consumers to the
        # published asset platforms.
        manifold-agent = final.callPackage ../pkgs/manifold-agent { };
        atyrode = final.callPackage ../pkgs/atyrode {
          capabilities = capabilitySummary;
          inherit homebrewCasks;
          hostRegistry = publicRegistry // publicRuntimeProfiles;
          revision = inventoryRevision;
          windowsPackages = windowsPackageInventory;
        };
      })
      (
        _final: previous:
        lib.optionalAttrs previous.stdenv.isDarwin {
          # nixpkgs Darwin fixup replaces Obsidian's Developer ID signature
          # with an ad-hoc one. The pinned upstream DMG and derivation audit
          # in #89 verified that skipping fixup preserves its signed bundle.
          obsidian = previous.obsidian.overrideAttrs (_: {
            dontFixup = true;
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
    homebrewCasks
    inventoryRevision
    mkPackageOverlay
    repositoryPackageNames
    repositoryPkgsFor
    windowsPackageInventory
    ;
}
