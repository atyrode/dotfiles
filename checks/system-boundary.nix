{
  darwinConfigs ? { },
  externalFixture ? null,
  homeConfigs,
  inventory,
  lib,
  pkgs,
  serverConfig ? null,
  system,
}:

let
  boundary = builtins.fromJSON (builtins.readFile ../inventory/system-boundary.json);
  darwinCasks = import ../darwin/casks.nix;
  knownCapabilities = builtins.attrNames (import ../home/profiles);

  sort = lib.sort builtins.lessThan;
  normaliseHome = value: if value ? config then value.config else value;
  normaliseDarwin = value: if value ? config then value.config else value;

  configuredHomes = map normaliseHome (builtins.attrValues homeConfigs);
  serverHomes = lib.optional (serverConfig != null) (normaliseHome serverConfig);
  externalSystem = if externalFixture == null then null else externalFixture.configuration.config;
  externalHomes = lib.optional (
    externalFixture != null
  ) externalSystem.home-manager.users.${externalFixture.host.username};
  configuredDarwin = map normaliseDarwin (builtins.attrValues darwinConfigs);
  darwinHomes = lib.concatMap (
    config: builtins.attrValues config.home-manager.users
  ) configuredDarwin;
  darwinHomePackages = lib.unique (lib.concatMap packageNames darwinHomes);
  portableHomes = configuredHomes ++ serverHomes ++ externalHomes ++ darwinHomes;

  packageNames = config: lib.unique (map lib.getName (config.home.packages or [ ]));
  hasCapability =
    capability: config: builtins.elem capability (config.atyrode.capabilities.selected or [ ]);
  hasAll = expected: actual: lib.all (package: builtins.elem package actual) expected;
  noManagedShell = config: !((config.home.sessionVariables or { }) ? SHELL);
  noClamAV = config: !(builtins.elem "clamav" (packageNames config));

  capabilityOwners = builtins.attrNames inventory.capabilities;
  inventoryPackages = lib.concatMap (
    capability:
    map (item: item.name) (
      lib.filter (item: item.kind == "package") inventory.capabilities.${capability}.deliverables
    )
  ) capabilityOwners;
  inventoryCasks = map (item: item.name) (
    lib.filter (item: item.kind == "application") inventory.capabilities.desktop.deliverables
  );
  packagesFor =
    owner:
    sort (
      map (item: item.name) (
        lib.filter (item: item.kind == "package") inventory.capabilities.${owner}.deliverables
      )
    );

  expectedContainerPackages =
    if lib.hasSuffix "-darwin" system then
      [
        "dive"
        "orbstack"
      ]
    else
      [
        "dive"
        "docker"
        "docker-compose"
      ];
  forbiddenContainerPackages =
    if lib.hasSuffix "-darwin" system then
      [
        "docker"
        "docker-compose"
      ]
    else
      [ "orbstack" ];
  containerHomes = builtins.filter (hasCapability "containers") portableHomes;
  containerHomeMatchesPolicy =
    config:
    let
      actual = packageNames config;
    in
    hasAll expectedContainerPackages actual
    && lib.intersectLists forbiddenContainerPackages actual == [ ];

  expectedOrder = [
    "login-shell"
    "nix-daemon"
    "nix-policy"
    "container-engine"
    "antivirus-data"
    "device-permissions"
    "homebrew-drift"
  ];
  officialCache = "https://cache.nixos.org/";
  officialKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";

  darwinPolicyMatches =
    config:
    let
      activation = config.system.activationScripts.postActivation.text;
      shellPaths = map toString config.environment.shells;
      sudoPam = config.security.pam.services.${boundary.sudo.darwinService};
      configuredCasks = map (
        cask: if builtins.isString cask then cask else cask.name
      ) config.homebrew.casks;
    in
    config.programs.zsh.enable
    && builtins.elem boundary.loginShell.darwinPath shellPaths
    && sudoPam.enable
    && sudoPam.touchIdAuth
    && sudoPam.reattach
    && config.users.users.${config.system.primaryUser}.shell == null
    && !(builtins.elem config.system.primaryUser config.users.knownUsers)
    && config.nix.settings.trusted-users == [ "root" ]
    && config.nix.settings.substituters == [ officialCache ]
    && config.nix.settings.trusted-public-keys == [ officialKey ]
    && config.nix.settings.require-sigs
    && config.nix.optimise.automatic
    && config.launchd.daemons."nix-optimise".serviceConfig.Label == boundary.nix.darwinOptimiserLabel
    && config.nix-homebrew.mutableTaps == false
    && config.homebrew.global.autoUpdate == false
    && config.homebrew.global.brewfile
    && config.homebrew.onActivation.autoUpdate == false
    && config.homebrew.onActivation.upgrade == false
    && config.homebrew.onActivation.cleanup == "check"
    && sort configuredCasks == sort darwinCasks
    && lib.hasInfix "/usr/bin/dscl" activation
    && lib.hasInfix "/run/current-system/sw/bin/zsh" activation
    && lib.hasInfix "refusing to create" activation;
in
assert lib.assertMsg (boundary.schemaVersion == 1) "unknown system-boundary policy schema";
assert lib.assertMsg (
  boundary.checkOrder == expectedOrder
) "system diagnostic order differs from the reviewed boundary";
assert lib.assertMsg (
  builtins.length boundary.checkOrder == builtins.length (lib.unique boundary.checkOrder)
) "system diagnostic identifiers must be unique";
assert lib.assertMsg (
  boundary.loginShell.program == "zsh"
  && boundary.loginShell.linuxPath == "$HOME/.nix-profile/bin/zsh"
  && boundary.loginShell.darwinPath == "/run/current-system/sw/bin/zsh"
  && boundary.loginShell.nixosPath == "/run/current-system/sw/bin/zsh"
) "login-shell ownership paths differ from the reviewed boundary";
assert lib.assertMsg (
  boundary.sudo.darwinService == "sudo_local" && boundary.sudo.touchIdAuth && boundary.sudo.reattach
) "Darwin sudo authentication differs from the reviewed boundary";
assert lib.assertMsg (
  boundary.nix.store == "daemon"
  && boundary.nix.trustedUsers == [ "root" ]
  && boundary.nix.substituter == officialCache
  && boundary.nix.trustedPublicKey == officialKey
) "Nix daemon, trust, or cache ownership differs from the reviewed boundary";
assert lib.assertMsg (
  boundary.containers.linux.requiredSecurityOption == "rootless"
  && boundary.containers.linux.forbiddenGroups == [ "docker" ]
  && boundary.containers.linux.socketTemplate == "/run/user/{uid}/docker.sock"
  && boundary.containers.darwin.context == "orbstack"
) "container-engine ownership differs from the reviewed boundary";
assert lib.assertMsg (
  boundary.antivirus.managed == false && boundary.antivirus.reason != ""
) "antivirus must remain explicitly unmanaged until a host owns updates and scanning";
assert lib.assertMsg (
  boundary.android.acceptedAccessPolicies == [
    "uaccess"
    "reviewed-user-group"
  ]
  && boundary.android.ruleIdentification == "filename-mentions-android-or-adb"
  &&
    boundary.android.acceptedGroups == [
      "adbusers"
      "plugdev"
    ]
) "Android device-access policy differs from the reviewed boundary";
assert lib.assertMsg (
  boundary.homebrew.cleanup == "check"
  &&
    boundary.homebrew.forbiddenAutomaticModes == [
      "uninstall"
      "zap"
    ]
) "Homebrew cleanup must remain report-only and non-destructive";
assert lib.assertMsg (
  sort capabilityOwners == sort knownCapabilities
) "the evaluated inventory has missing or unknown capability owners";
assert lib.assertMsg (
  builtins.length inventoryPackages == builtins.length (lib.unique inventoryPackages)
) "an evaluated package is assigned to more than one capability";
assert lib.assertMsg (
  packagesFor "containers" == sort expectedContainerPackages
) "container clients are not assigned coherently";
assert lib.assertMsg (
  packagesFor "security" == [
    "nmap"
    "socat"
  ]
) "the security capability must contain only the reviewed network diagnostics";
assert lib.assertMsg (
  !(builtins.elem "clamav" inventoryPackages)
) "ClamAV must remain absent until signature updates and scanning have a system owner";
assert lib.assertMsg (
  !lib.hasSuffix "-darwin" system || sort inventoryCasks == sort darwinCasks
) "evaluated nix-darwin Homebrew casks differ from the reviewed module";
assert lib.assertMsg (
  lib.intersectLists darwinCasks darwinHomePackages == [ ]
) "a Homebrew-owned Darwin cask is also installed by Home Manager";
assert lib.assertMsg (lib.all noManagedShell portableHomes)
  "Home Manager must not override SHELL; the account database owns the login shell";
assert lib.assertMsg (lib.all noClamAV portableHomes)
  "a portable Home Manager configuration unexpectedly installs ClamAV";
assert lib.assertMsg (lib.all containerHomeMatchesPolicy containerHomes)
  "the containers capability does not match the platform-specific client policy";
assert lib.assertMsg (
  externalFixture == null || externalSystem.programs.zsh.enable
) "the external NixOS consumer must own system Zsh enablement";
assert lib.assertMsg (
  externalFixture == null
  || lib.getName externalSystem.users.users.${externalFixture.host.username}.shell == "zsh"
) "the external NixOS consumer must own its account login shell";
assert lib.assertMsg (lib.all darwinPolicyMatches configuredDarwin)
  "nix-darwin shell, Nix daemon, or Homebrew policy differs from the reviewed boundary";
pkgs.runCommand "check-system-boundary-${system}" { } ''
  mkdir "$out"
''
