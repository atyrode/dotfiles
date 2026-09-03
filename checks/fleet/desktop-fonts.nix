{
  hostConfigs,
  lib,
  pkgs,
}:

let
  # The Nerd Font is a desktop concern: the operator workstation must render
  # powerline separators and Nerd glyphs in its terminal UIs, while headless
  # hosts have nothing to render and must not grow the font in their closure.
  mac = hostConfigs.macbook.config;
  macPackages = map lib.getName mac.home.packages;
  headlessPackages = lib.concatMap (name: map lib.getName hostConfigs.${name}.config.home.packages) [
    "dev-01"
    "wsl"
  ];
  nerdFont = pkgs.nerd-fonts.jetbrains-mono;
  nerdFontFile = "${nerdFont}/share/fonts/truetype/NerdFonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf";
in
assert lib.assertMsg (builtins.elem "nerd-fonts-jetbrains-mono" macPackages)
  "the Mac host must install the JetBrainsMono Nerd Font";
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
