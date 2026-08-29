{
  budgets,
  hostConfigs,
  lib,
  pkgs,
  system,
}:

let
  # Only hosts this system can realise, and only those carrying a budget.
  # A foreign-system activation package cannot be built here, and the desktop
  # and WSL hosts are intentionally unbudgeted (inventory/host-budgets.json).
  budgeted = lib.filterAttrs (name: _config: budgets ? ${name}) hostConfigs;

  measure =
    name: homeConfig:
    let
      budget = budgets.${name};
      packageNames = lib.unique (map lib.getName homeConfig.config.home.packages);
      packageCount = builtins.length packageNames;
    in
    assert lib.assertMsg (packageCount <= budget.maxTopLevelPackages)
      "host ${name} installs ${toString packageCount} top-level packages, over its budget of ${toString budget.maxTopLevelPackages} (inventory/host-budgets.json)";
    {
      inherit name budget packageCount;
      closure = pkgs.closureInfo { rootPaths = [ homeConfig.activationPackage ]; };
    };

  measured = lib.mapAttrsToList measure budgeted;

  enforce = m: ''
    nar_bytes="$(cat ${m.closure}/total-nar-size)"
    store_paths="$(wc -l < ${m.closure}/store-paths)"
    printf '%s: %s NAR bytes (max ${toString m.budget.maxNarBytes}), %s store paths (max ${toString m.budget.maxStorePaths}), ${toString m.packageCount} packages (max ${toString m.budget.maxTopLevelPackages})\n' \
      ${lib.escapeShellArg m.name} "$nar_bytes" "$store_paths"

    if [ "$nar_bytes" -gt ${toString m.budget.maxNarBytes} ]; then
      echo "host ${m.name} closure $nar_bytes exceeds its budget ${toString m.budget.maxNarBytes} (inventory/host-budgets.json)" >&2
      failed=1
    fi
    if [ "$store_paths" -gt ${toString m.budget.maxStorePaths} ]; then
      echo "host ${m.name} store path count $store_paths exceeds its budget ${toString m.budget.maxStorePaths} (inventory/host-budgets.json)" >&2
      failed=1
    fi

    report="$(jq -nc --argjson report "$report" \
      --arg host ${lib.escapeShellArg m.name} \
      --argjson narBytes "$nar_bytes" \
      --argjson storePaths "$store_paths" \
      '$report + [{
        host: $host,
        narBytes: $narBytes,
        storePaths: $storePaths,
        topLevelPackages: ${toString m.packageCount},
        maxNarBytes: ${toString m.budget.maxNarBytes},
        maxStorePaths: ${toString m.budget.maxStorePaths},
        maxTopLevelPackages: ${toString m.budget.maxTopLevelPackages}
      }]')"
  '';
in
pkgs.runCommand "check-host-closure-${system}"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    failed=0
    report='[]'
    ${lib.concatMapStrings enforce measured}
    [ "$failed" -eq 0 ] || exit 1
    mkdir -p "$out"
    printf '%s' "$report" | jq . > "$out/host-closure.json"
  ''
