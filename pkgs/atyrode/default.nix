{
  age,
  atyrode-tui,
  atyrodeTuiPackage ? atyrode-tui,
  bubblewrap,
  bitwarden-cli,
  capabilities,
  claude-code,
  clever-tools,
  codex,
  coreutils,
  curl,
  enableTestHooks ? false,
  findutils,
  # Published flake activated by `atyrode apply` without --repo. Must stay a
  # github: ref; the CLI derives the ls-remote URL from it.
  flakeRef ? "github:atyrode/dotfiles",
  revision ? "unknown",
  gawk,
  gitMinimal,
  gnugrep,
  homebrewCasks,
  hostname,
  hostRegistry,
  jq,
  lib,
  makeWrapper,
  nh,
  nix,
  openssh,
  openssl,
  omp-configured,
  python3,
  runtimeShell,
  stdenvNoCC,
  tmux,
  windowsPackages,
  writeShellApplication,
  zsh,
}:

let
  # The provisioning ceremony, wrapped so `atyrode apply` can offer it with no
  # checkout on disk and pinned to the same revision as the CLI offering it.
  # babel is deliberately absent from runtimeInputs: a machine with no babel is
  # not an archiving machine, apply stays silent there, and the CLI would
  # otherwise carry babel's closure to every host in the fleet.
  babelStorageConfigure = writeShellApplication {
    name = "babel-storage-configure";
    runtimeInputs = [
      bitwarden-cli
      clever-tools
      coreutils
      python3
    ];
    text = ''
      exec ${runtimeShell} ${../../scripts/babel-storage-configure.sh} "$@"
    '';
  };

  capabilityInventory = builtins.toFile "atyrode-capabilities.json" (builtins.toJSON capabilities);
  gitAllowedSigners = ../../home/git-allowed-signers;
  sshFleetKeys = ../../home/ssh-fleet-keys;
  homebrewCaskInventory = builtins.toFile "atyrode-homebrew-casks.json" (
    builtins.toJSON homebrewCasks
  );
  homebrewBrewfile = builtins.toFile "atyrode-Brewfile" (
    lib.concatStringsSep "\n" (
      [
        ''tap "homebrew/homebrew-core"''
        ''tap "homebrew/homebrew-cask"''
      ]
      ++ map (cask: ''cask "${cask}"'') homebrewCasks
    )
    + "\n"
  );
  registry = builtins.toFile "atyrode-host-registry.json" (builtins.toJSON hostRegistry);
  windowsPackageInventory = builtins.toFile "atyrode-windows-packages.json" (
    builtins.toJSON windowsPackages
  );
  operatorInfra = ../../inventory/operator-infra.json;
  manifoldInventory = ../../inventory/manifold.json;
  systemPolicy = ../../inventory/system-boundary.json;
  provisioningPolicy = ../../inventory/provisioning.json;
  tools = builtins.toFile "atyrode-tool-inventory.json" (
    builtins.toJSON [
      {
        name = "Nix";
        command = "nix";
        capability = "base";
        version = lib.getVersion nix;
        versionOwner = "pinned nixpkgs/system installer";
        mutableState = "shared Nix store and user evaluation caches";
        launchModes = [
          "build"
          "develop"
          "shell"
        ];
      }
      {
        name = "nh";
        command = "nh";
        capability = "base";
        version = lib.getVersion nh;
        versionOwner = "pinned nixpkgs";
        mutableState = "none beyond Nix state";
        launchModes = [
          "home"
          "darwin"
          "os"
        ];
      }
      {
        name = "Claude Code";
        command = "claude";
        capability = "agent-tools";
        version = lib.getVersion claude-code;
        versionOwner = "pinned nixpkgs";
        mutableState = "~/.claude and ~/.claude.json";
        launchModes = [
          "interactive"
          "print"
        ];
      }
      {
        name = "Codex";
        command = "codex";
        capability = "agent-tools";
        version = lib.getVersion codex;
        versionOwner = "repository package derivation";
        mutableState = "~/.codex";
        launchModes = [
          "interactive"
          "exec"
        ];
      }
      {
        name = "OMP";
        command = "omp";
        capability = "agent-tools";
        version = lib.getVersion omp-configured;
        versionOwner = "repository package derivation";
        mutableState = "profile-scoped auth, sessions, MCP state, and caches";
        launchModes = [
          "normal"
          "generated"
          "untrusted"
          "acp"
        ];
      }
      {
        name = "tmux adapter";
        command = "tmux";
        capability = "agent-tools";
        version = lib.getVersion tmux;
        versionOwner = "pinned nixpkgs";
        mutableState = "tmux server sockets and sessions";
        launchModes = [
          "interactive"
        ];
      }
      {
        name = "bubblewrap isolation backend";
        command = "bwrap";
        capability = "agent-tools";
        platform = "linux";
        version = lib.getVersion bubblewrap;
        versionOwner = "pinned nixpkgs";
        mutableState = "none";
        launchModes = [ "OMP task isolation" ];
      }
      {
        name = "comma";
        command = ",";
        capability = "base";
        version = "nix-index-database input";
        versionOwner = "pinned flake input";
        mutableState = "shared Nix store";
        launchModes = [ "on-demand command" ];
      }
      {
        name = "nix-index";
        command = "nix-locate";
        capability = "base";
        version = "nix-index-database input";
        versionOwner = "pinned flake input";
        mutableState = "immutable packaged index";
        launchModes = [ "lookup" ];
      }
      {
        name = "Zsh";
        command = "zsh";
        capability = "base";
        version = lib.getVersion zsh;
        versionOwner = "pinned nixpkgs";
        mutableState = "history and completion cache";
        launchModes = [
          "interactive"
          "login"
        ];
      }
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "atyrode";
  version = "0.1.0";
  src = ./atyrode;
  runtimeSrc = ./runtime;
  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;
  installPhase = ''
    install -D -m755 "$src" "$out/bin/atyrode"
    install -D -m755 "$runtimeSrc" "$out/libexec/atyrode-runtime"
    substituteInPlace "$out/libexec/atyrode-runtime" \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@omp_managed@' '${lib.getExe' omp-configured "omp-managed"}'
    substituteInPlace "$out/bin/atyrode" \
      --replace-fail '@atyrode_tui@' '${lib.getExe atyrode-tui}' \
      --replace-fail '@atyrode_preview_parser@' '${lib.getExe' atyrodeTuiPackage "atyrode-preview-parser"}' \
      --replace-fail '@babel_storage_configure@' '${lib.getExe babelStorageConfigure}' \
      --replace-fail '@atyrode_runtime@' "$out/libexec/atyrode-runtime" \
      --replace-fail '@capabilities@' '${capabilityInventory}' \
      --replace-fail '@flakeRef@' '${flakeRef}' \
      --replace-fail '@git_allowed_signers@' '${gitAllowedSigners}' \
      --replace-fail '@ssh_fleet_keys@' '${sshFleetKeys}' \
      --replace-fail '@homebrew_brewfile@' '${homebrewBrewfile}' \
      --replace-fail '@homebrew_casks@' '${homebrewCaskInventory}' \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@registry@' '${registry}' \
      --replace-fail '@revision@' '${revision}' \
      --replace-fail '@operator_infra@' '${operatorInfra}' \
      --replace-fail '@manifold_inventory@' '${manifoldInventory}' \
      --replace-fail '@system_policy@' '${systemPolicy}' \
      --replace-fail '@provisioning_policy@' '${provisioningPolicy}' \
      --replace-fail '@test_hooks@' '${if enableTestHooks then "1" else "0"}' \
      --replace-fail '@tools@' '${tools}' \
      --replace-fail '@windows_packages@' '${windowsPackageInventory}'
    wrapProgram "$out/bin/atyrode" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          age
          bitwarden-cli
          curl
          findutils
          gawk
          gitMinimal
          gnugrep
          hostname
          jq
          nh
          nix
          openssh
          openssl
        ]
      }
  '';

  meta = {
    description = "Safe operator and agent interface for atyrode dotfiles";
    license = lib.licenses.mit;
    mainProgram = "atyrode";
    platforms = lib.platforms.all;
  };
}
