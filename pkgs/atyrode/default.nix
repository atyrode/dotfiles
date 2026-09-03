{
  age,
  age-plugin-se,
  atyrode-tui,
  atyrodeTuiPackage ? atyrode-tui,
  bubblewrap,
  bitwarden-cli,
  capabilities,
  catalog,
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
  # Clan's registration directory the identity probes read: a machine or a
  # user is registered when its key.json is here. A check overrides it with
  # a fixture tree, the one way to reach the registered state without a real
  # recipient in the committed one.
  sopsDirectory ? ../../sops,
  stdenvNoCC,
  tmux,
  windowsPackages,
  writeShellApplication,
  zsh,
}:

let
  # The generated agent context asks Clever Cloud one question -- is there a
  # session here -- and a workstation rarely carries clever-tools itself. This
  # exposes one copy to the CLI so the probe has an answer on a machine that
  # has no clever of its own.
  babelClever = writeShellApplication {
    name = "babel-clever";
    runtimeInputs = [ clever-tools ];
    text = ''
      exec clever "$@"
    '';
  };

  capabilityInventory = builtins.toFile "atyrode-capabilities.json" (builtins.toJSON capabilities);
  catalogInventory = builtins.toFile "atyrode-catalog.json" (builtins.toJSON catalog);
  gitAllowedSigners = ../../modules/home/git/allowed-signers;
  agentsPolicy = ../../modules/home/agents/AGENTS.md;
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
  manifoldInventory = ../../fleet/manifold.json;
  authBrokerInventory = ../../fleet/auth-broker.json;
  systemPolicy = ../../fleet/system-boundary.json;
  provisioningPolicy = ../../fleet/provisioning.json;
  # The services whose disruption an unattended activation may never cause,
  # read by libexec/atyrode-disruption on every apply, rollback and fleet
  # deploy. Compiled in rather than read from the checkout so the policy a
  # closure is reviewed with is the policy that guards its activation.
  serviceProtection = ../../fleet/service-protection.json;
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
  libSrc = ./lib;
  runtimeSrc = ./runtime;
  disruptionSrc = ./disruption;
  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;
  installPhase = ''
    install -D -m755 "$src" "$out/bin/atyrode"
    install -d -m755 "$out/libexec/atyrode/lib"
    install -m644 "$libSrc"/*.sh "$out/libexec/atyrode/lib/"
    install -D -m755 "$runtimeSrc" "$out/libexec/atyrode-runtime"
    substituteInPlace "$out/libexec/atyrode-runtime" \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@omp_managed@' '${lib.getExe' omp-configured "omp-managed"}'
    install -D -m755 "$disruptionSrc" "$out/libexec/atyrode-disruption"
    substituteInPlace "$out/libexec/atyrode-disruption" \
      --replace-fail '@python3@' '${python3.interpreter}' \
      --replace-fail '@service_protection@' '${serviceProtection}'
    substituteInPlace "$out/bin/atyrode" \
      --replace-fail '@agents_policy@' '${agentsPolicy}' \
      --replace-fail '@atyrode_tui@' '${lib.getExe atyrode-tui}' \
      --replace-fail '@atyrode_preview_parser@' '${lib.getExe' atyrodeTuiPackage "atyrode-preview-parser"}' \
      --replace-fail '@atyrode_disruption@' "$out/libexec/atyrode-disruption" \
      --replace-fail '@babel_clever@' '${lib.getExe babelClever}' \
      --replace-fail '@atyrode_runtime@' "$out/libexec/atyrode-runtime" \
      --replace-fail '@capabilities@' '${capabilityInventory}' \
      --replace-fail '@catalog@' '${catalogInventory}' \
      --replace-fail '@flakeRef@' '${flakeRef}' \
      --replace-fail '@git_allowed_signers@' '${gitAllowedSigners}' \
      --replace-fail '@homebrew_brewfile@' '${homebrewBrewfile}' \
      --replace-fail '@homebrew_casks@' '${homebrewCaskInventory}' \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@registry@' '${registry}' \
      --replace-fail '@revision@' '${revision}' \
      --replace-fail '@sops_directory@' '${sopsDirectory}' \
      --replace-fail '@manifold_inventory@' '${manifoldInventory}' \
      --replace-fail '@auth_broker_inventory@' '${authBrokerInventory}' \
      --replace-fail '@system_policy@' '${systemPolicy}' \
      --replace-fail '@provisioning_policy@' '${provisioningPolicy}' \
      --replace-fail '@lib_dir@' "$out/libexec/atyrode/lib" \
      --replace-fail '@test_hooks@' '${if enableTestHooks then "1" else "0"}' \
      --replace-fail '@tools@' '${tools}' \
      --replace-fail '@windows_packages@' '${windowsPackageInventory}'
    wrapProgram "$out/bin/atyrode" \
      --prefix PATH : ${
        lib.makeBinPath (
          [
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
          # The operator ceremony runs only where the Secure Enclave is, and
          # the plugin's Linux closure is a Swift runtime no Linux host needs
          # (modules/home/profiles/security.nix says why).
          ++ lib.optional stdenvNoCC.hostPlatform.isDarwin age-plugin-se
        )
      }
  '';

  meta = {
    description = "Safe operator and agent interface for atyrode dotfiles";
    license = lib.licenses.mit;
    mainProgram = "atyrode";
    platforms = lib.platforms.all;
  };
}
