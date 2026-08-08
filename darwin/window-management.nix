{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;

  # A border on a lone window disambiguates nothing, so hide it and bring it
  # back the moment a second window becomes visible. JankyBorders has no
  # built-in solo-window option (verified against the 1.9.0 binary), so yabai
  # signals drive the running instance. Restoring re-executes the Home
  # Manager-generated bordersrc, which keeps the width and palette in exactly
  # one place instead of duplicating them here.
  bordersSolo = pkgs.writeShellApplication {
    name = "borders-solo";
    runtimeInputs = [
      pkgs.yabai
      pkgs.jq
      pkgs.jankyborders
    ];
    text = ''
      visible=$(yabai -m query --windows --space | jq '[.[] | select(."is-visible")] | length')
      if [ "$visible" -le 1 ]; then
        borders width=0.0
      else
        "$HOME/.config/borders/bordersrc"
      fi
    '';
  };
  bordersSoloEvents = [
    "window_created"
    "window_destroyed"
    "window_focused"
    "window_minimized"
    "window_deminimized"
    "space_changed"
    "display_changed"
  ];
  bordersSoloSignals = lib.concatMapStrings (event: ''
    ${yabai} -m signal --add label=borders-solo-${event} event=${event} action='${lib.getExe bordersSolo}'
  '') bordersSoloEvents;
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
      ${bordersSoloSignals}
      ${lib.getExe bordersSolo}
    '';
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
      EnvironmentVariables.PATH = "${pkgs.yabai}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      KeepAlive = true;
      ProcessType = "Interactive";
      RunAtLoad = true;
    };

    managedBy = "darwin/window-management.nix";
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
