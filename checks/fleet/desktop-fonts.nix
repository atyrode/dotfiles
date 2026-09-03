{
  hostConfigs,
  lib,
  pkgs,
}:

let
  # The Nerd Font is a desktop concern: both operator workstations must render
  # powerline separators and Nerd glyphs in their terminal UIs, while headless
  # hosts have nothing to render and must not grow the font in their closure.
  mac = hostConfigs.macbook.config;
  linuxDesktop = hostConfigs.workstation-x86_64-linux.config;
  headless = hostConfigs.platform-01.config;
  macPackages = map lib.getName mac.home.packages;
  linuxDesktopPackages = map lib.getName linuxDesktop.home.packages;
  headlessPackages = map lib.getName headless.home.packages;
  nerdFont = pkgs.nerd-fonts.jetbrains-mono;
  nerdFontFile = "${nerdFont}/share/fonts/truetype/NerdFonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf";
in
assert lib.assertMsg (builtins.elem "nerd-fonts-jetbrains-mono" macPackages)
  "the Mac host must install the JetBrainsMono Nerd Font";
assert lib.assertMsg (builtins.elem "nerd-fonts-jetbrains-mono" linuxDesktopPackages)
  "the Linux desktop host must install the JetBrainsMono Nerd Font";
assert lib.assertMsg (
  !(builtins.elem "nerd-fonts-jetbrains-mono" headlessPackages)
) "the Nerd Font is a desktop concern; headless hosts must not carry it";
pkgs.runCommand "check-desktop-fonts"
  {
    nativeBuildInputs = [ pkgs.fontconfig ];
  }
  ''
    # The monospace Nerd Font face must exist under the name terminal UIs
    # request, so a nixpkgs repackaging cannot silently move or rename it.
    test -f ${nerdFontFile}
    fc-scan --format '%{family}\n' ${nerdFontFile} | grep -q "JetBrainsMono Nerd Font Mono"

    mkdir "$out"
  ''
