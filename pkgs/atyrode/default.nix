{
  bubblewrap,
  capabilities,
  claude-code,
  codex,
  coreutils,
  enableTestHooks ? false,
  findutils,
  # Published flake activated by `atyrode apply` without --repo. Must stay a
  # github: ref; the CLI derives the ls-remote URL from it.
  flakeRef ? "github:atyrode/dotfiles",
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
  omp-configured,
  runtimeShell,
  stdenvNoCC,
  tmux,
  zsh,
}:

let
  capabilityInventory = builtins.toFile "atyrode-capabilities.json" (builtins.toJSON capabilities);
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
  systemPolicy = ../../inventory/system-boundary.json;
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
        mutableState = "~/.codex and ~/.codex-profiles";
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
          "preset"
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
  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;
  installPhase = ''
    install -D -m755 "$src" "$out/bin/atyrode"
    substituteInPlace "$out/bin/atyrode" \
      --replace-fail '@capabilities@' '${capabilityInventory}' \
      --replace-fail '@flakeRef@' '${flakeRef}' \
      --replace-fail '@homebrew_brewfile@' '${homebrewBrewfile}' \
      --replace-fail '@homebrew_casks@' '${homebrewCaskInventory}' \
      --replace-fail '@shell@' '${runtimeShell}' \
      --replace-fail '@registry@' '${registry}' \
      --replace-fail '@system_policy@' '${systemPolicy}' \
      --replace-fail '@test_hooks@' '${if enableTestHooks then "1" else "0"}' \
      --replace-fail '@tools@' '${tools}'
    wrapProgram "$out/bin/atyrode" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          findutils
          gawk
          gitMinimal
          gnugrep
          hostname
          jq
          nh
          nix
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
