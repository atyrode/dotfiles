{
  lib,
  pkgs,
  serverHomeConfig,
  serverPolicy,
  system,
}:

let
  packageNames = lib.sort builtins.lessThan (
    lib.unique (map lib.getName serverHomeConfig.config.home.packages)
  );
  packageCount = builtins.length packageNames;
  budget = serverPolicy.closureBudgets.${system};
  closure = pkgs.closureInfo {
    rootPaths = [ serverHomeConfig.activationPackage ];
  };
  manifest = pkgs.writeText "server-profile-${system}.json" (
    builtins.toJSON {
      inherit (serverPolicy)
        capabilities
        excludedCapabilities
        mutableStateOwnedOutsideNix
        productionFacts
        profile
        schemaVersion
        systemOwned
        ;
      inherit system;
      packages = packageNames;
      topLevelPackageCount = {
        actual = packageCount;
        max = budget.maxTopLevelPackages;
      };
      closure = {
        root = "home-activation";
        inherit (budget) maxNarBytes maxStorePaths;
      };
    }
  );
in
assert lib.assertMsg (packageCount <= budget.maxTopLevelPackages)
  "server profile top-level package count ${toString packageCount} exceeds budget ${toString budget.maxTopLevelPackages}";
pkgs.runCommand "server-profile-manifest-${system}"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    actual_nar_bytes="$(cat ${closure}/total-nar-size)"
    actual_store_paths="$(wc -l < ${closure}/store-paths)"

    if [ "$actual_nar_bytes" -gt ${toString budget.maxNarBytes} ]; then
      echo "server profile NAR size $actual_nar_bytes exceeds budget ${toString budget.maxNarBytes}" >&2
      exit 1
    fi
    if [ "$actual_store_paths" -gt ${toString budget.maxStorePaths} ]; then
      echo "server profile store path count $actual_store_paths exceeds budget ${toString budget.maxStorePaths}" >&2
      exit 1
    fi

    mkdir -p "$out/share/atyrode"
    jq \
      --argjson actualNarBytes "$actual_nar_bytes" \
      --argjson actualStorePaths "$actual_store_paths" \
      '.closure += {
        actualNarBytes: $actualNarBytes,
        actualStorePaths: $actualStorePaths
      }' \
      ${manifest} > "$out/manifest.json"
    cp "$out/manifest.json" "$out/share/atyrode/server-profile.json"
    ln -s ${serverHomeConfig.activationPackage} "$out/home-activation"
  ''
