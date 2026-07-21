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
  rioFont = pkgs.nerd-fonts.jetbrains-mono;
  rioFontFile = "${rioFont}/share/fonts/truetype/NerdFonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf";
in
assert lib.assertMsg (builtins.elem "rio" macPackages)
  "the Mac host must carry the pinned Rio terminal (#278)";
assert lib.assertMsg (builtins.elem "rio" linuxDesktopPackages)
  "the Linux desktop host must carry the pinned Rio terminal (#278)";
assert lib.assertMsg (builtins.elem "nerd-fonts-jetbrains-mono" macPackages)
  "the Mac host must install Rio's shared Nerd Font";
assert lib.assertMsg (builtins.elem "nerd-fonts-jetbrains-mono" linuxDesktopPackages)
  "the Linux desktop host must install Rio's shared Nerd Font";
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
pkgs.runCommand "check-rio"
  {
    nativeBuildInputs = [
      pkgs.fontconfig
      pkgs.taplo
    ];
  }
  ''
    # The committed config must parse and carry the operator policy: portable
    # Rio tabs/splits plus the Rio-scoped OMP image protocol override.
    [ "$(taplo get -f ${committedConfig} 'navigation.mode')" = TopTab ]
    [ "$(taplo get -f ${committedConfig} 'navigation.use-split')" = true ]
    [ "$(taplo get -f ${committedConfig} 'navigation.hide-if-single')" = true ]
    [ "$(taplo get -f ${committedConfig} 'env-vars[0]')" = PI_FORCE_IMAGE_PROTOCOL=kitty ]
    [ "$(taplo get -f ${committedConfig} 'option-as-alt')" = left ]
    [ "$(taplo get -f ${committedConfig} 'fonts.family')" = "JetBrainsMono Nerd Font Mono" ]
    test -f ${rioFontFile}
    fc-scan --format '%{family}\n' ${rioFontFile} | grep -q "JetBrainsMono Nerd Font Mono"
    [ "$(taplo get -f ${committedConfig} 'colors.background')" = "#282C34" ]
    [ "$(taplo get -f ${committedConfig} 'colors.foreground')" = "#FFFFFF" ]
    [ "$(taplo get -f ${committedConfig} 'colors.black')" = "#1D1F21" ]
    [ "$(taplo get -f ${committedConfig} 'colors.red')" = "#CC6666" ]
    [ "$(taplo get -f ${committedConfig} 'colors.green')" = "#B5BD68" ]
    [ "$(taplo get -f ${committedConfig} 'colors.yellow')" = "#F0C674" ]
    [ "$(taplo get -f ${committedConfig} 'colors.blue')" = "#81A2BE" ]
    [ "$(taplo get -f ${committedConfig} 'colors.magenta')" = "#B294BB" ]
    [ "$(taplo get -f ${committedConfig} 'colors.cyan')" = "#8ABEB7" ]
    [ "$(taplo get -f ${committedConfig} 'colors.white')" = "#C5C8C6" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-black')" = "#666666" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-red')" = "#D54E53" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-green')" = "#B9CA4A" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-yellow')" = "#E7C547" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-blue')" = "#7AA6DA" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-magenta')" = "#C397D8" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-cyan')" = "#70C0B1" ]
    [ "$(taplo get -f ${committedConfig} 'colors.light-white')" = "#EAEAEA" ]

    # Rio ignores header-less keys that appear after the first [section]; the
    # env-vars override must therefore stay at the top of the file.
    awk '/^\[/ { exit !found } /^env-vars/ { found = 1 } END { exit !found }' \
      ${committedConfig}

    mkdir "$out"
  ''
