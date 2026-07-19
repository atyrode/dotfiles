{
  hostConfigs,
  lib,
  pkgs,
}:

let
  # Rio (#278) is a desktop concern: both operator workstations render the
  # terminal from the one committed TOML, and the Windows lock artifact must
  # never drift from the nixpkgs pin — a floating installer would silently
  # break the "pinned cross-platform layer" contract.
  mac = hostConfigs.alex-aarch64-darwin.config;
  linuxDesktop = hostConfigs.alex-x86_64-linux-desktop.config;
  headless = hostConfigs.alex-x86_64-linux.config;
  macPackages = map lib.getName mac.home.packages;
  linuxDesktopPackages = map lib.getName linuxDesktop.home.packages;
  headlessPackages = map lib.getName headless.home.packages;
  lock = builtins.fromJSON (builtins.readFile ../inventory/rio-windows.json);
  committedConfig = ../home/rio/config.toml;
in
assert lib.assertMsg (builtins.elem "rio" macPackages)
  "the Mac host must carry the pinned Rio terminal (#278)";
assert lib.assertMsg (builtins.elem "rio" linuxDesktopPackages)
  "the Linux desktop host must carry the pinned Rio terminal (#278)";
assert lib.assertMsg (
  !(builtins.elem "rio" headlessPackages)
) "Rio is a desktop concern; headless hosts must not grow a GUI terminal";
assert lib.assertMsg (
  mac.xdg.configFile."rio/config.toml".source == linuxDesktop.xdg.configFile."rio/config.toml".source
) "every Rio host must render the one committed home/rio/config.toml";
assert lib.assertMsg (
  lock.schemaVersion == 1
) "inventory/rio-windows.json schema changed unexpectedly";
assert lib.assertMsg (lock.version == pkgs.rio.version)
  "inventory/rio-windows.json pins Rio ${lock.version} but nixpkgs pins ${pkgs.rio.version}: one review bumps both together (#278)";
assert lib.assertMsg (lib.hasInfix "/v${lock.version}/" lock.installer.url)
  "the Windows installer URL must point at the pinned Rio release tag";
assert lib.assertMsg (
  builtins.match "[0-9a-f]{64}" lock.installer.sha256 != null
) "the Windows installer lock must carry a full lowercase SHA256";
assert lib.assertMsg (
  lock.config.source == "home/rio/config.toml"
) "the Windows config deployment must consume the committed Rio TOML";
pkgs.runCommand "check-rio" { nativeBuildInputs = [ pkgs.taplo ]; } ''
  # The committed config must parse and carry the operator policy: Rio as a
  # thin renderer (herdr owns multiplexing) and the Rio-scoped OMP image
  # protocol override.
  [ "$(taplo get -f ${committedConfig} 'navigation.mode')" = Plain ]
  [ "$(taplo get -f ${committedConfig} 'navigation.use-split')" = false ]
  [ "$(taplo get -f ${committedConfig} 'navigation.hide-if-single')" = true ]
  [ "$(taplo get -f ${committedConfig} 'env-vars[0]')" = PI_FORCE_IMAGE_PROTOCOL=kitty ]

  # Rio ignores header-less keys that appear after the first [section]; the
  # env-vars override must therefore stay at the top of the file.
  awk '/^\[/ { exit !found } /^env-vars/ { found = 1 } END { exit !found }' \
    ${committedConfig}

  mkdir "$out"
''
