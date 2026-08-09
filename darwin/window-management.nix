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

      # The bar floats at the top edge; the native menu bar auto-hides
      # (reachable by mousing to the top). Reserve the ported bar's full
      # vertical footprint -- height 39 plus y_offset 10, both read from the
      # reference sketchybarrc; the check derives this sum from the rc file.
      external_bar = "all:49:0";
    };

    # Utility float rules, plus the two yabai->SketchyBar bridges the ported
    # reference config expects: window_focus drives the yabai state item and
    # windows_on_spaces rebuilds the per-Space app-icon strips.
    extraConfig = ''
      ${yabai} -m rule --add label=system-settings app='^System Settings$' manage=off
      ${yabai} -m rule --add label=calculator app='^Calculator$' manage=off
      ${yabai} -m signal --add label=bar-window-focus event=window_focused action='${sketchybarBin} --trigger window_focus'
      ${yabai} -m signal --add label=bar-windows-created event=window_created action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-windows-destroyed event=window_destroyed action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-windows-moved event=window_moved action='${sketchybarBin} --trigger windows_on_spaces'
      ${yabai} -m signal --add label=bar-space-changed event=space_changed action='${sketchybarBin} --trigger windows_on_spaces'
      ${sketchybarBin} --trigger windows_on_spaces
    '';
  };

  # SketchyBar renders yabai/OS state; it owns no windows and no hotkeys.
  # The configuration is a faithful port of FelixKratz/dotfiles@e6288b3 -- the
  # upstream README-screenshot bar -- deployed as his literal file tree to
  # ~/.config/sketchybar by Home Manager (see home/macos-window-management.nix).
  # `config` stays unset here so the daemon reads that tree exactly as
  # upstream's does. Deviations live in the tree, each marked in-file: no
  # compiled CPU helper, no Spotify media widget (its event class is dead on
  # macOS 26), System Settings instead of the retired System Preferences, and
  # the space_eager fast-highlight event the keyboard bindings feed.
  services.sketchybar = {
    enable = true;
    extraPackages = [
      pkgs.yabai
      pkgs.jq
      pkgs.gh
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

  # SketchyBar owns the top edge, so the native menu bar auto-hides; it stays
  # reachable by mousing to the top of the screen.
  fonts.packages = [ pkgs.sketchybar-app-font ];

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
