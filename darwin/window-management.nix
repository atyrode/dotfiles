{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;
  sketchybarBin = "${pkgs.sketchybar}/bin/sketchybar";
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

      # DATUM is a full-width 40pt instrument face whose first datum band sits
      # below the physical notch. The native menu bar auto-hides (reachable by
      # mousing to the top); reserve exactly the measured face height from
      # settings.lua so tiled windows never overlap it.
      external_bar = "all:40:0";
    };

    # Utility float rules, plus the yabai->SketchyBar bridges DATUM consumes:
    # window_focus enriches the active-app title and windows_on_spaces rebuilds
    # the filtered per-Space app-icon groups.
    extraConfig = ''
      ${yabai} -m rule --add label=system-settings app='^System Settings$' manage=off
      ${yabai} -m rule --add label=calculator app='^Calculator$' manage=off
      ${yabai} -m signal --add label=bar-window-focus event=window_focused action='${sketchybarBin} --trigger window_focus'
      ${yabai} -m signal --add label=bar-windows-created event=window_created action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-windows-destroyed event=window_destroyed action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-windows-moved event=window_moved action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-space-changed event=space_changed action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-space-created event=space_created action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-space-destroyed event=space_destroyed action='${sketchybarBin} --trigger windows_on_spaces'
      ${sketchybarBin} --trigger windows_on_spaces
    '';
  };

  # SketchyBar renders yabai/OS state; it owns no windows and no hotkeys.
  # The DATUM configuration is Lua on the resident SbarLua runtime: a solid,
  # notch-aware instrument face with semantic deck/track/ink tokens and
  # measured geometry. Home Manager recursively deploys the Lua tree and its
  # generated Lua 5.5 bootstrap; `config` stays unset so that bootstrap remains
  # the sole runtime entry point.
  services.sketchybar = {
    enable = true;
    extraPackages = [
      pkgs.yabai
      pkgs.lua5_5
      pkgs.curl
    ];
  };

  # Tahoe keys Accessibility grants to a stable app identity. The classic
  # nixpkgs skhd binary lives at a generation-specific store path, so launch
  # the pinned skhd.zig app bundle while retaining nix-darwin lifecycle.
  environment.etc."skhdrc".text = builtins.readFile ./window-management/skhdrc;

  launchd.user.agents.skhd = {
    serviceConfig = {
      ProgramArguments = [
        "/Applications/skhd.app/Contents/MacOS/skhd"
        "-c"
        "/etc/skhdrc"
      ];
      EnvironmentVariables.PATH = "${pkgs.yabai}/bin:${pkgs.sketchybar}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      KeepAlive = true;
      ProcessType = "Interactive";
      RunAtLoad = true;
    };

    managedBy = "darwin/window-management.nix";
  };

  # Hammerspoon owns native top-edge, Wi-Fi, and battery event bridges for
  # SketchyBar. Same Tahoe pattern as skhd: launch the app bundle for a stable
  # Accessibility identity while nix-darwin owns the lifecycle.
  launchd.user.agents.hammerspoon = {
    serviceConfig = {
      ProgramArguments = [ "/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon" ];
      KeepAlive = true;
      ProcessType = "Interactive";
      RunAtLoad = true;
    };

    managedBy = "darwin/window-management.nix";
  };

  # SketchyBar owns the top edge, so the native menu bar auto-hides; it stays
  # reachable by mousing to the top of the screen. DATUM uses JetBrains Mono
  # Nerd Font for measured values and glyphs, and DM Sans for named state.
  fonts.packages = [
    pkgs.nerd-fonts.jetbrains-mono
    (pkgs.google-fonts.override { fonts = [ "DM Sans" ]; })
  ];

  system.defaults = {
    dock.mru-spaces = false;
    spaces.spans-displays = false;

    NSGlobalDomain._HIHideMenuBar = true;

    WindowManager = {
      GloballyEnabled = false;
      EnableStandardClickToShowDesktop = false;
      StandardHideDesktopIcons = false;
      HideDesktop = false;
    };
  };
}
