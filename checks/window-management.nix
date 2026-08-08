{
  darwinConfig,
  homeConfig,
  lib,
  pkgs,
}:

let
  cfg = darwinConfig.config;
  packageNames = map lib.getName homeConfig.config.home.packages;
  caskName = cask: if builtins.isString cask then cask else cask.name;
  caskNames = map caskName cfg.homebrew.casks;
  skhdConfig = cfg.environment.etc.skhdrc.text;
  skhdArguments = cfg.launchd.user.agents.skhd.serviceConfig.ProgramArguments;
  requiredBindings = [
    "ctrl + alt + cmd - h : yabai -m window --focus west"
    "ctrl + alt + cmd + shift - l : yabai -m window --warp east"
    "ctrl + alt + cmd - 1 : yabai -m space --focus 1"
    "ctrl + alt + cmd - 9 : yabai -m space --focus 9"
    "ctrl + alt + cmd + shift - 1 : yabai -m window --space 1"
    "ctrl + alt + cmd + shift - 9 : yabai -m window --space 9"
    "ctrl + alt + cmd - space : yabai -m window --toggle float"
    "ctrl + alt + cmd - f : yabai -m window --toggle zoom-fullscreen"
    "ctrl + alt + cmd - r ; resize"
    "resize < escape ; default"
  ];
  missingBindings = lib.filter (binding: !(lib.hasInfix binding skhdConfig)) requiredBindings;
in
assert lib.assertMsg cfg.services.yabai.enable "the Darwin workstation must enable yabai";
assert lib.assertMsg (
  !cfg.services.yabai.enableScriptingAddition
) "yabai's scripting addition must remain disabled while full SIP is retained";
assert lib.assertMsg (
  cfg.services.yabai.config.layout == "bsp"
  && cfg.services.yabai.config.split_ratio == 0.50
  && cfg.services.yabai.config.window_placement == "second_child"
) "yabai must retain the conservative BSP baseline";
assert lib.assertMsg (
  cfg.services.yabai.config.top_padding == 8
  && cfg.services.yabai.config.bottom_padding == 8
  && cfg.services.yabai.config.left_padding == 8
  && cfg.services.yabai.config.right_padding == 8
  && cfg.services.yabai.config.window_gap == 8
) "yabai must retain equal initial gaps and padding";
assert lib.assertMsg (
  !cfg.services.skhd.enable
  &&
    skhdArguments == [
      "/Applications/skhd.app/Contents/MacOS/skhd"
      "-c"
      "/etc/skhdrc"
    ]
) "the Darwin workstation must launch the stable skhd app bundle";
assert lib.assertMsg (missingBindings == [ ]) (
  "skhd is missing required window-management bindings: " + lib.concatStringsSep ", " missingBindings
);
assert lib.assertMsg (
  !cfg.system.defaults.dock.mru-spaces
  && !cfg.system.defaults.spaces.spans-displays
  && !cfg.system.defaults.WindowManager.GloballyEnabled
  && !cfg.system.defaults.WindowManager.EnableStandardClickToShowDesktop
  && !cfg.system.defaults.WindowManager.StandardHideDesktopIcons
  && !cfg.system.defaults.WindowManager.HideDesktop
) "macOS defaults must preserve stable, separate Spaces without Stage Manager";
assert lib.assertMsg (
  builtins.hasAttr "jackielii/homebrew-tap" cfg.nix-homebrew.taps
  && builtins.elem "jackielii/tap/skhd-zig" caskNames
) "nix-homebrew must pin and install the Tahoe-compatible skhd.zig app bundle";
assert lib.assertMsg (
  !(builtins.elem "skhd" packageNames) && builtins.elem "yabai" packageNames
) "the desktop capability must expose yabai without the obsolete classic skhd package";
pkgs.runCommand "check-window-management-${pkgs.system}" { } ''
  mkdir "$out"
''
