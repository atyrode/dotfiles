{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;

  # Shared palette, same source of truth the rest of the stack uses: Rio's
  # background, foreground, and vi-cursor accent (see home/rio/config.toml).
  barHeight = 30;
  colorBar = "0xff282c34";
  colorLabel = "0xffffffff";
  colorAccent = "0xff70c0b1";
  colorDim = "0xff3e4451";

  # SketchyBar visualizes yabai/OS state but owns none of it. Every item is
  # event-driven; the only timers are the clock and the battery percentage,
  # which have no native events to subscribe to.
  #
  # One plugin owns all Space-item state -- existence, focus, occupancy -- so
  # there is exactly one writer and no ordering race between subscribers of the
  # same event. It runs on space events only: an event-triggered yabai query,
  # never a polling loop. Items for Spaces that do not currently exist are
  # hidden entirely, i3-style. label.alpha is not a real SketchyBar property
  # (silently ignored), so occupancy dims through label.color. The focused
  # numeral flips dark against the accent pill.
  spacesPlugin = pkgs.writeShellApplication {
    name = "sketchybar-spaces";
    runtimeInputs = [
      pkgs.sketchybar
      pkgs.yabai
      pkgs.jq
      pkgs.gawk
    ];
    text = ''
      spaces=$(yabai -m query --spaces | jq -r '.[] | "\(.index) \(.windows | length) \(."has-focus")"')
      for index in 1 2 3 4 5 6 7 8 9; do
        # awk always exits 0, so an absent index stays errexit-safe.
        row=$(printf '%s\n' "$spaces" | awk -v idx="$index" '$1 == idx { print $2, $3 }')
        if [ -z "$row" ]; then
          sketchybar --set "space.$index" drawing=off
          continue
        fi
        count=''${row% *}
        focused=''${row#* }
        if [ "$focused" = "true" ]; then
          sketchybar --set "space.$index" drawing=on background.drawing=on label.color=${colorBar}
        elif [ "$count" -gt 0 ]; then
          sketchybar --set "space.$index" drawing=on background.drawing=off label.color=${colorLabel}
        else
          sketchybar --set "space.$index" drawing=on background.drawing=off label.color=${colorDim}
        fi
      done
    '';
  };

  frontAppPlugin = pkgs.writeShellApplication {
    name = "sketchybar-front-app";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      # $INFO carries the application name on front_app_switched.
      sketchybar --set "$NAME" label="''${INFO:-}"
    '';
  };

  clockPlugin = pkgs.writeShellApplication {
    name = "sketchybar-clock";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      sketchybar --set "$NAME" label="$(date '+%a %d %b  %H:%M')"
    '';
  };

  batteryPlugin = pkgs.writeShellApplication {
    name = "sketchybar-battery";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      status=$(/usr/bin/pmset -g batt)
      percent=$(printf '%s' "$status" | /usr/bin/grep -oE '[0-9]+%' | head -1)
      case $status in
        *'AC Power'*) icon='~' ;;
        *) icon='%' ;;
      esac
      sketchybar --set "$NAME" label="$icon $percent"
    '';
  };

  # Space items are passive click targets; spacesPlugin is their only writer.
  spaceItems = lib.concatMapStrings (index: ''
    sketchybar --add space space.${index} left \
      --set space.${index} space=${index} label=${index} label.padding_left=8 label.padding_right=8 \
        background.corner_radius=4 background.height=20 background.color=${colorAccent} background.drawing=off \
        drawing=off \
        click_script='${yabai} -m space --focus ${index}'
  '') (map toString (lib.range 1 9));
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

      # The bar sits at the bottom so the native menu bar stays untouched while
      # SketchyBar proves itself (issue #360 phase 4). Reserve exactly the bar
      # height so tiles never underlap it; the check pins this equality.
      external_bar = "all:0:${toString barHeight}";
    };

    # Start with utility windows whose floating behavior is predictable. Add
    # application routing only after the manual Space workflow has settled.
    extraConfig = ''
      ${yabai} -m rule --add label=system-settings app='^System Settings$' manage=off
      ${yabai} -m rule --add label=calculator app='^Calculator$' manage=off
    '';
  };

  # SketchyBar renders yabai/OS state; it owns no windows and no hotkeys. All
  # items are event-driven. wifi_change is documented broken since Sonoma and
  # media_change is deprecated on macOS 26, so neither appears here.
  services.sketchybar = {
    enable = true;
    config = ''
      sketchybar --bar position=bottom height=${toString barHeight} color=${colorBar} padding_left=8 padding_right=8

      sketchybar --default label.font="Helvetica:Bold:13.0" label.color=${colorLabel} \
        icon.font="Helvetica:Bold:13.0" icon.color=${colorLabel} \
        background.color=${colorDim} background.drawing=off

      ${spaceItems}
      sketchybar --add item front_app left \
        --set front_app label.padding_left=12 script='${lib.getExe frontAppPlugin}' \
        --subscribe front_app front_app_switched

      sketchybar --add item clock right \
        --set clock update_freq=30 script='${lib.getExe clockPlugin}'

      sketchybar --add item battery right \
        --set battery update_freq=120 script='${lib.getExe batteryPlugin}' \
        --subscribe battery power_source_change system_woke

      sketchybar --add item spaces_driver left \
        --set spaces_driver drawing=off script='${lib.getExe spacesPlugin}' \
        --subscribe spaces_driver space_change space_windows_change display_change

      # Populate initial Space state without waiting for the first event.
      ${lib.getExe spacesPlugin}

      sketchybar --update
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
