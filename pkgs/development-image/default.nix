{
  lib,
  stdenv,
  dockerTools,
  writeTextDir,
  writeShellScriptBin,
  runCommand,
  bash,
  coreutils,
  util-linux,
  getent,
  nix,
  tini,
  iana-etc,
  mkPortableHomeConfiguration,
  revision,
}:
let
  system = stdenv.hostPlatform.system;
  homeDirectory = "/home/developer";
  loginShell = "${homeDirectory}/.nix-profile/bin/zsh";
  portableHome = mkPortableHomeConfiguration {
    profileName = "development-${system}";
    username = "developer";
    inherit homeDirectory;
  };
  containerLifecycleModule = {
    home.uid = 1000;
    atyrode.agentTools.seedSpeechModels = false;
    atyrode.agentTools.localClassifier.enable = false;
    atyrode.agentTools.resourceGuard.enable = false;
    services.ssh-agent.enable = lib.mkForce false;
  };
  home = portableHome.extendModules { modules = [ containerLifecycleModule ]; };
  runtimePackages = [
    nix
    tini
    bash
    coreutils
    util-linux
    getent
  ];
  runtimePath = lib.makeBinPath runtimePackages;
  caFile = "/etc/ssl/certs/ca-certificates.crt";
  substitutions = {
    inherit homeDirectory runtimePath caFile;
    bash = "${bash}/bin/bash";
    env = "${coreutils}/bin/env";
    stat = "${coreutils}/bin/stat";
    mkdir = "${coreutils}/bin/mkdir";
    chmod = "${coreutils}/bin/chmod";
    sleep = "${coreutils}/bin/sleep";
    timeout = "${coreutils}/bin/timeout";
    setpriv = "${util-linux}/bin/setpriv";
    nix = "${nix}/bin/nix";
    nixDaemon = "${nix}/bin/nix-daemon";
    activation = "${home.activationPackage}/activate";
    activationPackage = toString home.activationPackage;
    sessionVariables = "${home.config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
  };
  session = writeShellScriptBin "development-session" (
    lib.replaceStrings (lib.mapAttrsToList (
      name: _: "@${name}@"
    ) substitutions) (lib.attrValues substitutions) (builtins.readFile ./session.sh)
  );
  entrypointSubstitutions = substitutions // {
    session = "${session}/bin/development-session";
  };
  entrypoint = writeShellScriptBin "development-entrypoint" (
    lib.replaceStrings (lib.mapAttrsToList (name: _: "@${name}@")
      entrypointSubstitutions
    ) (lib.attrValues entrypointSubstitutions) (builtins.readFile ./entrypoint.sh)
  );
  boundary = builtins.fromJSON (builtins.readFile ../../fleet/system-boundary.json);
  caches = import ../../modules/shared/binary-caches.nix;
  nixConfig = writeTextDir "etc/nix/nix.conf" ''
    substituters = ${lib.concatStringsSep " " caches.substituters}
    trusted-public-keys = ${lib.concatStringsSep " " caches.trusted-public-keys}
    trusted-users = ${lib.concatStringsSep " " boundary.nix.trustedUsers}
    allowed-users = *
    require-sigs = true
    build-users-group = nixbld
    experimental-features = nix-command flakes
    sandbox = false
  '';
  buildUsers = lib.range 1 32;
  nss = dockerTools.fakeNss.override {
    extraPasswdLines = [
      "developer:!:1000:1000:Development user:${homeDirectory}:${loginShell}"
    ]
    ++ map (
      id: "nixbld${toString id}:!:${toString (30000 + id)}:30000:Nix build user:/var/empty:/bin/false"
    ) buildUsers;
    extraGroupLines = [
      "developer:!:1000:"
      "nixbld:!:30000:${lib.concatMapStringsSep "," (id: "nixbld${toString id}") buildUsers}"
    ];
  };
  filesystem = runCommand "development-filesystem" { } ''
    mkdir -p $out/bin $out/etc
    ln -s ${bash}/bin/bash $out/bin/bash
    ln -s ${coreutils}/bin/false $out/bin/false
    printf '%s\n' '${loginShell}' '/bin/bash' '/bin/sh' > $out/etc/shells
  '';
  # Only the filesystem is linked at /. Closure roots retain every runtime
  # reference for includeNixDB without exposing activation files at the root.
  closureRoots = runCommand "development-closure-roots" { } ''
    mkdir -p $out/etc/development-image/closure
    ${lib.concatMapStringsSep "\n"
      (path: ''
        ln -s ${path} $out/etc/development-image/closure/${builtins.baseNameOf (toString path)}
      '')
      (
        [
          home.activationPackage
          home.config.home.path
          home.config.home.sessionVariablesPackage
          session
          entrypoint
        ]
        ++ runtimePackages
      )
    }
  '';
in
assert stdenv.hostPlatform.isLinux;
dockerTools.buildLayeredImage {
  name = "ghcr.io/atyrode/development";
  tag = revision;
  includeNixDB = true;
  includeStorePaths = true;
  contents = [
    nss
    nixConfig
    filesystem
    closureRoots
    dockerTools.binSh
    dockerTools.usrBinEnv
    dockerTools.caCertificates
    iana-etc
  ];
  fakeRootCommands = ''
    mkdir -p ./home/developer ./workspace ./tmp ./root ./var/empty \
      ./nix/store ./nix/var/nix/{daemon-socket,db,profiles/per-user,gcroots/per-user}
    chown -R 0:0 ./nix ./root
    chown 1000:1000 ./home/developer ./workspace
    chmod 0700 ./root
    chmod 1777 ./tmp
    chmod 0755 ./home ./home/developer ./workspace ./var/empty \
      ./nix ./nix/store ./nix/var ./nix/var/nix \
      ./nix/var/nix/{daemon-socket,db,profiles,profiles/per-user,gcroots,gcroots/per-user}
  '';
  config = {
    User = "0:0";
    WorkingDir = "/workspace";
    Entrypoint = [
      "${tini}/bin/tini"
      "-g"
      "--"
      "${entrypoint}/bin/development-entrypoint"
    ];
    Cmd = [
      loginShell
      "-l"
    ];
    Env = [
      "HOME=${homeDirectory}"
      "USER=developer"
      "LOGNAME=developer"
      "XDG_CONFIG_HOME=${homeDirectory}/.config"
      "XDG_CACHE_HOME=${homeDirectory}/.cache"
      "XDG_DATA_HOME=${homeDirectory}/.local/share"
      "XDG_STATE_HOME=${homeDirectory}/.local/state"
      "NIX_REMOTE=daemon"
      "LANG=C.UTF-8"
      "TERM=xterm-256color"
      "SHELL=${loginShell}"
      "SSL_CERT_FILE=${caFile}"
      "NIX_SSL_CERT_FILE=${caFile}"
      "PATH=${home.config.home.path}/bin:${runtimePath}:/usr/local/bin:/bin:/usr/bin"
    ];
    Labels = {
      "org.opencontainers.image.source" = "https://github.com/atyrode/dotfiles";
      "org.opencontainers.image.revision" = revision;
    };
  };
}
