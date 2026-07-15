{
  annotations,
  capabilityModules,
  darwinConfigs,
  home-manager,
  homeConfigs,
  hosts,
  lib,
  pkgs,
  repositoryPackageNames,
  revision,
  system,
}:

let
  platform = if lib.hasSuffix "-darwin" system then "darwin" else "linux";
  capabilityNames = builtins.attrNames capabilityModules;
  annotationNames = builtins.attrNames annotations.capabilities;
  allowedAnnotationKeys = [
    "consumer"
    "deliveryBoundary"
    "group"
    "mutableState"
    "purpose"
    "platforms"
    "securityBoundary"
    "title"
  ];

  packageName = package: package.pname or (lib.getName package);
  packageVersion = package:
    let version = package.version or (lib.getVersion package);
    in if version == "" || version == packageName package then "unknown" else version;
  packageDescription = package:
    let description = package.meta.description or "";
    in if builtins.isString description && description != "" then description
       else "${packageName package} package (upstream metadata unavailable)";
  packageHomepage = package:
    let homepage = package.meta.homepage or null;
    in if builtins.isString homepage then homepage
       else if builtins.isList homepage && homepage != [ ] then builtins.head homepage
       else null;
  packageRecord = package:
    assert lib.assertMsg (
      !(builtins.elem (packageName package) repositoryPackageNames)
      || (builtins.isString (package.meta.description or "")
        && (package.meta.description or "") != "")
    ) "repository package ${packageName package} must provide useful meta.description";
    {
      kind = "package";
      name = packageName package;
      version = packageVersion package;
      description = packageDescription package;
      homepage = packageHomepage package;
      delivery = "home-manager";
      source = if builtins.elem (packageName package) repositoryPackageNames
        then "repository-overlay"
        else "pinned-nixpkgs";
      inherit platform system;
    };
  caskRecord = name: {
    kind = "application";
    inherit name platform system;
    version = "pinned-tap";
    description = "${name} macOS application (Homebrew metadata unavailable during pure evaluation)";
    homepage = null;
    delivery = "nix-darwin-homebrew-cask";
    source = "pinned-homebrew-cask-tap";
  };

  packageMap = packages: builtins.listToAttrs (map (package:
    lib.nameValuePair (packageName package) package
  ) packages);
  sortedNames = packages: lib.sort builtins.lessThan (builtins.attrNames (packageMap packages));

  mkEvaluation = modules: home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = modules ++ [{
      home.username = "inventory";
      home.homeDirectory = if platform == "darwin" then "/Users/inventory" else "/home/inventory";
      home.stateVersion = "26.05";
      home.sessionVariables.ATYRODE_HOST = "inventory";
      xdg.configFile."atyrode/host.json".text = "{}";
    }];
  };
  baselineConfig = mkEvaluation [ ];
  baseConfig = mkEvaluation [ capabilityModules.base ];
  baselineNames = sortedNames baselineConfig.config.home.packages;
  baseNames = sortedNames baseConfig.config.home.packages;
  capabilityPlatforms = name:
    annotations.capabilities.${name}.platforms or [ "darwin" "linux" ];
  capabilitySupported = name: builtins.elem platform (capabilityPlatforms name);
  configForCapability = name:
    if name == "base" then baseConfig
    else mkEvaluation [ capabilityModules.base capabilityModules.${name} ];
  packageNamesForCapability = name:
    if !capabilitySupported name then [ ]
    else lib.subtractLists baseNames (sortedNames (configForCapability name).config.home.packages)
      ++ lib.optionals (name == "base") (lib.subtractLists baselineNames baseNames);
  packagesForCapability = name:
    if !capabilitySupported name then [ ]
    else
      let packages = packageMap (configForCapability name).config.home.packages;
      in map (packageName: packageRecord packages.${packageName})
        (lib.sort builtins.lessThan (lib.unique (packageNamesForCapability name)));

  systemHosts = lib.filterAttrs (_: host: host.system == system) hosts;
  selectedOnHosts = capability: lib.sort builtins.lessThan
    (lib.filter (name: builtins.elem capability systemHosts.${name}.capabilities)
      (builtins.attrNames systemHosts));
  caskName = cask: if builtins.isString cask then cask else cask.name;
  evaluatedCasks = lib.unique (map caskName (lib.concatMap
    (name: darwinConfigs.${name}.config.homebrew.casks or [ ])
    (builtins.attrNames darwinConfigs)));
  casks = map caskRecord (lib.sort builtins.lessThan evaluatedCasks);

  capabilityDeliverables = name:
    packagesForCapability name
    ++ lib.optionals (platform == "darwin" && name == annotations.homebrewCaskOwner) casks;
  capabilities = lib.genAttrs capabilityNames (name:
    annotations.capabilities.${name} // {
      inherit name;
      applicable = capabilitySupported name;
      platforms = capabilityPlatforms name;
      marker = capabilityDeliverables name == [ ];
      selectedOnHosts = selectedOnHosts name;
      deliverables = capabilityDeliverables name;
    });

  ownerEntries = capabilities: lib.concatMap
    (capability: map (deliverable: {
      inherit capability;
      inherit (deliverable) name;
    }) capabilities.${capability}.deliverables)
    (builtins.attrNames capabilities);
  duplicateNames = entries:
    let names = map (entry: entry.name) entries;
    in lib.filter (name: builtins.length (lib.filter (other: other == name) names) > 1)
      (lib.unique names);
  hostManifest = name: host:
    let
      selectedCapabilities = host.capabilities;
      entries = ownerEntries (lib.filterAttrs
        (capability: _: builtins.elem capability selectedCapabilities) capabilities);
      actualPackages = lib.subtractLists baselineNames
        (sortedNames homeConfigs.${name}.config.home.packages);
      attributedPackages = lib.sort builtins.lessThan (lib.unique
        (map (entry: entry.name) (lib.filter
          (entry: capabilities.${entry.capability}.deliverables != [ ]
            && (builtins.head (lib.filter
              (deliverable: deliverable.name == entry.name)
              capabilities.${entry.capability}.deliverables)).kind == "package") entries)));
      actualCasks = if platform == "darwin" then
        lib.sort builtins.lessThan (lib.unique
          (map caskName darwinConfigs.${name}.config.homebrew.casks))
      else [ ];
      attributedCasks = lib.sort builtins.lessThan (map (item: item.name)
        (lib.filter (item: item.kind == "application")
          capabilities.${annotations.homebrewCaskOwner}.deliverables));
    in
    assert lib.assertMsg (duplicateNames entries == [ ])
      "inventory duplicate ownership for host ${name}: ${lib.concatStringsSep ", " (duplicateNames entries)}";
    assert lib.assertMsg (actualPackages == attributedPackages)
      "inventory package attribution is incomplete for host ${name}";
    assert lib.assertMsg (actualCasks == attributedCasks)
      "inventory cask attribution is incomplete for host ${name}";
    {
      id = name;
      inherit (host) aliases description homeDirectory hostname platform system username;
      capabilities = selectedCapabilities;
      deliverables = map (entry: entry // {
        item = builtins.head (lib.filter
          (deliverable: deliverable.name == entry.name)
          capabilities.${entry.capability}.deliverables);
      }) entries;
    };
  hostManifests = lib.mapAttrs hostManifest systemHosts;

  unknownAnnotationKeys = lib.concatMap
    (name: map (key: "${name}.${key}")
      (lib.subtractLists allowedAnnotationKeys
        (builtins.attrNames annotations.capabilities.${name})))
    annotationNames;
  allCapabilityEntries = ownerEntries capabilities;
in
assert lib.assertMsg (annotations.schemaVersion == 1) "unknown inventory annotation schema";
assert lib.assertMsg (annotationNames == capabilityNames)
  "inventory annotations must cover capabilities exactly";
assert lib.assertMsg (unknownAnnotationKeys == [ ])
  "unknown inventory annotation keys: ${lib.concatStringsSep ", " unknownAnnotationKeys}";
assert lib.assertMsg (builtins.hasAttr annotations.homebrewCaskOwner capabilities)
  "unknown Homebrew cask owner capability";
assert lib.assertMsg (revision != "") "inventory revision must not be empty";
assert lib.assertMsg (duplicateNames allCapabilityEntries == [ ])
  "inventory duplicate capability ownership: ${lib.concatStringsSep ", " (duplicateNames allCapabilityEntries)}";
assert lib.assertMsg (capabilities.server.marker && capabilities.server.deliverables == [ ])
  "server must remain a deliberate empty marker capability";
assert lib.assertMsg (platform != "darwin" || casks != [ ])
  "Darwin inventory must contain evaluated Homebrew casks";
assert lib.assertMsg (platform == "darwin" || casks == [ ])
  "Linux inventory must not contain Homebrew casks";
{
  schemaVersion = 1;
  identity = {
    inherit revision system platform;
  };
  authority = {
    membership = "evaluated Home Manager and nix-darwin configurations";
    intent = "inventory/annotations.nix";
    closureIncluded = false;
    mutableStateIncluded = false;
  };
  inherit capabilities;
  hosts = hostManifests;
  boundaries = annotations.externalItems;
}
