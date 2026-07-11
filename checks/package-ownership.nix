{
  lib,
  pkgs,
  serverConfig ? null,
  serverPolicy,
}:

let
  matrix = ../inventory/packages.json;
  serverPackages =
    if serverConfig == null then [ ] else lib.unique (map lib.getName serverConfig.home.packages);
  leakedServerPackages = lib.intersectLists serverPackages serverPolicy.forbiddenTopLevelPackages;
  missingServerPackages = lib.subtractLists serverPackages serverPolicy.requiredTopLevelPackages;
  selectedCapabilities =
    if serverConfig == null then
      [ ]
    else
      lib.sort builtins.lessThan serverConfig.atyrode.capabilities.selected;
  expectedCapabilities = lib.sort builtins.lessThan serverPolicy.capabilities;
in
assert lib.assertMsg (serverPolicy.schemaVersion == 1) "unknown server profile policy schema";
assert lib.assertMsg (
  serverPolicy.profile == "server"
) "server profile policy has the wrong profile";
assert lib.assertMsg (
  serverPolicy.supportedSystems == [
    "aarch64-linux"
    "x86_64-linux"
  ]
) "server profile policy must support exactly the two Linux architectures";
assert lib.assertMsg (
  serverPolicy.productionFacts == [ ]
) "server profile policy must not contain production facts";
assert lib.assertMsg (lib.all
  (budget: budget.maxNarBytes > 0 && budget.maxStorePaths > 0 && budget.maxTopLevelPackages > 0)
  (builtins.attrValues serverPolicy.closureBudgets)
) "server profile budgets must set positive closure and package ceilings";
assert lib.assertMsg (
  serverConfig == null || leakedServerPackages == [ ]
) "server capability leaked forbidden packages: ${lib.concatStringsSep ", " leakedServerPackages}";
assert lib.assertMsg (serverConfig == null || missingServerPackages == [ ])
  "server capability is missing required packages: ${lib.concatStringsSep ", " missingServerPackages}";
assert lib.assertMsg (
  serverConfig == null || selectedCapabilities == expectedCapabilities
) "server capability selection does not match the reviewed policy";
pkgs.runCommand "check-package-ownership"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    jq -e '
      length > 0
      and all(.[];
        (.owner | type == "string" and length > 0)
        and (.deliveryLayer | type == "string" and length > 0)
        and (.selectedBy | type == "array")
        and (.consumer | type == "string" and length > 0)
        and (.versionOwner | type == "string" and length > 0)
        and (.mutableState | type == "string" and length > 0)
        and (.closureClass | type == "string" and length > 0)
        and (.packages | type == "array" and length > 0))
      and ([.[].packages[]] | length == (unique | length))
    ' ${matrix} >/dev/null
    mkdir "$out"
  ''
