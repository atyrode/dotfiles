# Host/bootstrap target registry: capability modules, registry loading and
# validation, public target projections, and the hosts.tsv projection consumed
# by get.sh before Nix exists.
{ lib, nix-index-database }:

let
  systems = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];

  rawCapabilityModules = import ../home/profiles;

  mkCapabilityModule = name: module: {
    imports = [
      ../modules/home/capability-contract.nix
      module
    ];

    atyrode.capabilities.selected = [ name ];
  };

  capabilityModules = lib.mapAttrs mkCapabilityModule rawCapabilityModules // {
    base = {
      imports = [
        ../modules/home/capability-contract.nix
        rawCapabilityModules.base
        nix-index-database.homeModules.default
      ];

      atyrode.capabilities.selected = [ "base" ];
      programs.nix-index.enable = true;
      programs.nix-index-database.comma.enable = true;
    };
  };
  knownCapabilities = builtins.attrNames capabilityModules;
  inventoryAnnotations = import ../inventory/annotations.nix;
  capabilityDescriptions = lib.mapAttrs (
    _: annotation: annotation.purpose
  ) inventoryAnnotations.capabilities;
  capabilitySummary =
    assert lib.assertMsg (
      builtins.attrNames capabilityDescriptions == knownCapabilities
    ) "capability annotations must cover the capability set exactly";
    map (name: {
      inherit name;
      description = capabilityDescriptions.${name};
    }) knownCapabilities;
  serverPolicy = builtins.fromJSON (builtins.readFile ../inventory/server-profile.json);
  serverCapabilities = serverPolicy.capabilities;
  rawHosts = import ../hosts;
  rawBootstrapProfiles = import ../hosts/bootstrap.nix;

  validateCapabilities =
    {
      capabilities,
      name ? "composition",
      system,
    }:
    assert lib.assertMsg (builtins.elem system systems) "${name} uses unsupported system ${system}";
    assert lib.assertMsg (capabilities != [ ]) "${name} must select at least one capability";
    assert lib.assertMsg (builtins.elem "base" capabilities) "${name} must select the base capability";
    assert lib.assertMsg (
      !(builtins.elem "server" capabilities && builtins.elem "desktop" capabilities)
    ) "${name} cannot combine server and desktop capabilities";
    assert lib.assertMsg (
      !(builtins.elem "server" capabilities && builtins.elem "development" capabilities)
    ) "${name} cannot combine server and development capabilities";
    assert lib.assertMsg (
      !builtins.elem "server" capabilities || lib.hasSuffix "-linux" system
    ) "${name} can select the server capability only on Linux";
    assert lib.assertMsg (
      builtins.length capabilities == builtins.length (lib.unique capabilities)
    ) "${name} declares duplicate capabilities";
    assert lib.assertMsg (lib.all (
      capability: builtins.hasAttr capability capabilityModules
    ) capabilities) "${name} declares an unknown capability";
    capabilities;

  validateHost =
    name: host:
    let
      expectedPlatform = if lib.hasSuffix "-darwin" host.system then "darwin" else "linux";
      activation = host.activation or null;
      nixTrustedUsers = host.nixTrustedUsers or null;
      capabilities = validateCapabilities {
        inherit name;
        inherit (host) system;
        capabilities = host.capabilities or [ ];
      };
    in
    assert lib.assertMsg (builtins.elem host.system systems)
      "host ${name} uses unsupported system ${host.system}";
    assert lib.assertMsg (
      host.platform == expectedPlatform
    ) "host ${name} platform ${host.platform} does not match ${host.system}";
    assert lib.assertMsg (builtins.elem activation [
      "home-manager"
      "nix-darwin"
      "nixos"
      "nixos-wsl"
    ]) "host ${name} must declare a supported activation owner";
    assert lib.assertMsg (
      if host.platform == "darwin" then
        activation == "nix-darwin"
      else
        builtins.elem activation [
          "home-manager"
          "nixos"
          "nixos-wsl"
        ]
    ) "host ${name} activation owner ${toString activation} does not match platform ${host.platform}";
    assert lib.assertMsg (
      activation != "nixos-wsl" || builtins.isString (host.hostname or null)
    ) "NixOS-WSL host ${name} must declare a stable hostname";
    assert lib.assertMsg (
      nixTrustedUsers == null
      || (
        builtins.isList nixTrustedUsers
        && nixTrustedUsers != [ ]
        && lib.all (user: builtins.isString user && user != "") nixTrustedUsers
        && builtins.length nixTrustedUsers == builtins.length (lib.unique nixTrustedUsers)
      )
    ) "host ${name} declares invalid or duplicate Nix trusted users";
    assert lib.assertMsg (
      activation != "nixos" || (nixTrustedUsers != null && builtins.elem "root" nixTrustedUsers)
    ) "NixOS host ${name} must explicitly declare Nix trusted users including root";
    assert lib.assertMsg (
      builtins.isString host.username && host.username != ""
    ) "host ${name} must declare a non-empty username";
    assert lib.assertMsg (
      builtins.isString host.homeDirectory && lib.hasPrefix "/" host.homeDirectory
    ) "host ${name} must declare an absolute homeDirectory";
    assert lib.assertMsg (builtins.isString (
      host.description or ""
    )) "host ${name} description must be a string";
    host
    // {
      inherit capabilities;
      inherit activation;
      description = host.description or "";
      hostname = host.hostname or null;
      inherit nixTrustedUsers;
    };

  validateBootstrapProfile =
    name: profile:
    let
      capabilities = validateCapabilities {
        inherit name;
        inherit (profile) system;
        capabilities = profile.capabilities or [ ];
      };
    in
    assert lib.assertMsg (lib.hasSuffix "-linux" profile.system)
      "bootstrap profile ${name} must target Linux";
    assert lib.assertMsg (
      profile.platform == "linux"
    ) "bootstrap profile ${name} must declare the Linux platform";
    assert lib.assertMsg (
      profile.activation == "home-manager"
    ) "bootstrap profile ${name} must use Home Manager activation";
    assert lib.assertMsg (
      !(profile ? username) && !(profile ? homeDirectory)
    ) "bootstrap profile ${name} must not declare account identity";
    assert lib.assertMsg (
      builtins.isString (profile.description or "") && profile.description != ""
    ) "bootstrap profile ${name} must declare a description";
    profile
    // {
      inherit capabilities;
      identityMode = "runtime";
    };

  validateBootstrapProfileRegistry = registry: lib.mapAttrs validateBootstrapProfile registry;

  validateHostRegistry = registry: lib.mapAttrs validateHost registry;

  hosts = validateHostRegistry rawHosts;
  bootstrapProfiles =
    assert lib.assertMsg (
      lib.intersectAttrs rawHosts rawBootstrapProfiles == { }
    ) "fixed hosts and portable bootstrap profiles must use distinct IDs";
    validateBootstrapProfileRegistry rawBootstrapProfiles;

  publicBootstrapProfile = name: profile: {
    id = name;
    inherit (profile)
      activation
      capabilities
      description
      identityMode
      platform
      system
      ;
  };
  publicHost = name: host: {
    id = name;
    inherit (host)
      activation
      capabilities
      description
      homeDirectory
      hostname
      platform
      system
      nixTrustedUsers
      username
      ;
    identityMode = "fixed";
  };
  publicHosts = lib.mapAttrs publicHost hosts;
  publicBootstrapProfiles = lib.mapAttrs publicBootstrapProfile bootstrapProfiles;
  publicTargets = publicHosts // publicBootstrapProfiles;
  fixedBootstrapHosts = lib.filterAttrs (
    _: host:
    !builtins.elem host.activation [
      "nixos"
      "nixos-wsl"
    ]
  ) publicHosts;
  bootstrapTargets = fixedBootstrapHosts // publicBootstrapProfiles;
  targetRegistryJson = builtins.toJSON publicTargets;
  # Flat projection consumed by the macOS/Linux get.sh before Nix exists.
  # Infrastructure-owned NixOS and repository-owned NixOS-WSL hosts are
  # excluded; the target-registry check keeps the projection honest.
  hostsTsv = lib.concatMapStrings (
    name:
    let
      target = bootstrapTargets.${name};
    in
    "${name}\t${target.system}\t${lib.concatStringsSep "," target.capabilities}\t${target.description}\n"
  ) (builtins.attrNames bootstrapTargets);

  mkHostIdentityModule =
    {
      host,
      name,
    }:
    let
      validated = validateHost name host;
    in
    {
      home.sessionVariables = {
        ATYRODE_HOST = name;
        ATYRODE_CAPABILITIES = lib.concatStringsSep "," validated.capabilities;
      };

      xdg.configFile."atyrode/host.json".text = builtins.toJSON (publicHost name validated);
    };

  selectHomeManagerProfiles =
    {
      capabilities,
      name ? "composition",
      system,
    }:
    map (capability: capabilityModules.${capability}) (validateCapabilities {
      inherit capabilities name system;
    });

  modulesForHost =
    name: host:
    selectHomeManagerProfiles {
      inherit name;
      inherit (host) capabilities system;
    }
    ++ [ (mkHostIdentityModule { inherit host name; }) ];
in
{
  inherit
    bootstrapProfiles
    capabilityDescriptions
    capabilityModules
    capabilitySummary
    hosts
    hostsTsv
    inventoryAnnotations
    knownCapabilities
    mkHostIdentityModule
    modulesForHost
    publicBootstrapProfile
    publicBootstrapProfiles
    publicHost
    publicHosts
    publicTargets
    rawBootstrapProfiles
    rawHosts
    selectHomeManagerProfiles
    serverCapabilities
    serverPolicy
    systems
    targetRegistryJson
    validateBootstrapProfileRegistry
    validateHostRegistry
    ;
}
