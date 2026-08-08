{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;
in
{
  services.yabai = {
    enable = true;
    package = pkgs.yabai;
    enableScriptingAddition = false;

    config = {
      layout = "bsp";
      split_ratio = 0.50;
      auto_balance = "off";
      window_placement = "second_child";

      focus_follows_mouse = "off";
      mouse_follows_focus = "off";

      top_padding = 8;
      bottom_padding = 8;
      left_padding = 8;
      right_padding = 8;
      window_gap = 8;
    };

    # Start with utility windows whose floating behavior is predictable. Add
    # application routing only after the manual Space workflow has settled.
    extraConfig = ''
      ${yabai} -m rule --add label=system-settings app='^System Settings$' manage=off
      ${yabai} -m rule --add label=calculator app='^Calculator$' manage=off
    '';
  };

  services.skhd = {
    enable = true;
    package = pkgs.skhd;
    skhdConfig = builtins.readFile ./window-management/skhdrc;
  };

  system.defaults = {
    dock.mru-spaces = false;
    spaces.spans-displays = false;

    WindowManager = {
      GloballyEnabled = false;
      EnableStandardClickToShowDesktop = false;
      StandardHideDesktopIcons = false;
      HideDesktop = false;
    };
  };
}
