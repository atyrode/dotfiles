{
  hostConfigs,
  lib,
  nixpkgs,
  pkgs,
}:

let
  catalog = import ../../fleet/catalog.nix;
  fleetSystems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
  names = builtins.attrNames catalog;

  # An entry is a claim about a package, and the claim this check defends is
  # the systems list: the surfaces refuse to launch an entry the current
  # machine is not named in, so a wrong list is a tool the operator is told he
  # cannot run, or worse, one offered on a machine where it cannot build.
  packageFor =
    system: attribute:
    lib.attrByPath (lib.splitString "." attribute) null nixpkgs.legacyPackages.${system};
  supportsSystem =
    system: attribute:
    let
      package = packageFor system attribute;
    in
    package != null && builtins.elem system (package.meta.platforms or [ ]);

  # The catalog exists to hold what no machine declares. An entry that a
  # profile already installs is dead weight in a list the operator reads to
  # remember what he has, so the overlap is a failure rather than a warning.
  declared = lib.unique (
    lib.concatMap (host: map lib.getName hostConfigs.${host}.config.home.packages) (
      builtins.attrNames hostConfigs
    )
  );

  malformed = builtins.filter (
    name:
    let
      entry = catalog.${name};
    in
    !(builtins.isString (entry.attribute or null))
    || !(builtins.isString (entry.reason or null))
    || !lib.hasSuffix "." (entry.reason or "")
    || !(builtins.isList (entry.systems or null))
    || entry.systems == [ ]
    || builtins.any (system: !builtins.elem system fleetSystems) entry.systems
  ) names;

  unsupported = lib.concatMap (
    name:
    map (system: "${name} on ${system}") (
      builtins.filter (system: !supportsSystem system catalog.${name}.attribute) catalog.${name}.systems
    )
  ) names;

  duplicated = builtins.filter (name: builtins.elem catalog.${name}.attribute declared) names;
in
assert lib.assertMsg (malformed == [ ])
  "catalog entries must carry an attribute, a reason ending in a period, and a non-empty systems list drawn from the fleet's systems: ${toString malformed}";
assert lib.assertMsg (unsupported == [ ])
  "a catalog entry may only claim a system the package itself supports, or the operator is offered a tool that cannot build there: ${toString unsupported}";
assert lib.assertMsg (duplicated == [ ])
  "the catalog holds what no machine declares; these entries are already installed by a profile: ${toString duplicated}";
pkgs.runCommand "check-fleet-catalog" { } ''
  mkdir "$out"
''
