{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;

  # Shared palette, same source of truth the rest of the stack uses: Rio's
  # background, foreground, and vi-cursor accent (see home/rio/config.toml).
  # The two structural grays and the warning colors follow the proportions of
  # FelixKratz's reference SketchyBar setup, which this bar's visual recipe is
  # lifted from; they are chrome, not theme, so the check pins only the accent.
  barHeight = 40;
  barYOffset = 8;
  colorBarBg = "0xf0282c34";
  colorLabel = "0xffffffff";
  colorAccent = "0xff70c0b1";
  colorGray1 = "0xff333743";
  colorGray2 = "0xff3e4451";
  colorEdge = "0xff181c22";
  colorWarn = "0xfff39660";
  colorCrit = "0xfffc5d7c";
  appFont = "${pkgs.sketchybar-app-font}/bin/icon_map.sh";

  # SketchyBar visualizes yabai/OS state but owns none of it. Every item is
  # event-driven; the only timers are the clock and the battery percentage,
  # which have no native events to subscribe to.
  #
  # One plugin owns all Space-item state -- existence, focus, occupancy and the
  # per-Space application icons -- so there is exactly one writer and no
  # ordering race between subscribers of the same event. Everything lands in a
  # single animated sketchybar invocation: nine separate --set calls cost
  # ~125ms per event and read as visible lag on a space switch.
  #
  # The focused accent is NOT set here: the items carry static
  # highlight_colors in the config (where the check pins the palette) and the
  # driver only flips the highlight booleans.
  spacesPlugin = pkgs.writeShellApplication {
    name = "sketchybar-spaces";
    runtimeInputs = [
      pkgs.sketchybar
      pkgs.yabai
      pkgs.jq
    ];
    text = ''
      declare -A count focus icons
      while read -r index windows focused; do
        count[$index]=$windows
        focus[$index]=$focused
      done < <(yabai -m query --spaces | jq -r '.[] | "\(.index) \(.windows | length) \(."has-focus")"')

      # App-icon ligatures per Space, rendered by sketchybar-app-font. One
      # icon_map lookup per unique app; duplicates within a Space collapse.
      declare -A seen
      while IFS=$'\t' read -r space app; do
        key="$space::$app"
        [ -n "''${seen[$key]:-}" ] && continue
        seen[$key]=1
        icons[$space]="''${icons[$space]:-}$('${appFont}' "$app") "
      done < <(yabai -m query --windows | jq -r '.[] | select(."is-minimized" | not) | "\(.space)\t\(.app)"')

      args=()
      for index in 1 2 3 4 5 6 7 8 9; do
        if [ -z "''${count[$index]:-}" ]; then
          args+=(--set "space.$index" drawing=off)
          continue
        fi
        if [ "''${focus[$index]}" = "true" ]; then
          highlight=on
          edge=${colorEdge}
        else
          highlight=off
          edge=${colorGray2}
        fi
        args+=(
          --set "space.$index" drawing=on
          "icon.highlight=$highlight" "label.highlight=$highlight"
          background.border_color="$edge"
          label="''${icons[$index]:-}"
        )
      done
      sketchybar --animate tanh 10 "''${args[@]}"
    '';
  };

  # Eager highlight for keyboard switches. macOS emits space_change only when
  # the slide animation commits, and yabai keeps reporting the old Space until
  # then (verified: a query issued right after --focus still returns the
  # origin). A trackpad swipe has no knowable destination, but the skhd
  # bindings do -- they announce it through a custom event, and this handler
  # flips highlights query-free while the slide is still animating. The
  # authoritative spacesPlugin settles occupancy when space_change lands.
  spacesEagerPlugin = pkgs.writeShellApplication {
    name = "sketchybar-spaces-eager";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      target=''${TARGET:-}
      [ -n "$target" ] || exit 0
      args=()
      for index in 1 2 3 4 5 6 7 8 9; do
        if [ "$index" = "$target" ]; then
          highlight=on
          edge=${colorEdge}
        else
          highlight=off
          edge=${colorGray2}
        fi
        args+=(
          --set "space.$index"
          "icon.highlight=$highlight" "label.highlight=$highlight"
          "background.border_color=$edge"
        )
      done
      # No --animate here: highlight booleans apply at animation END, which
      # would defeat the eager path's entire purpose (~166ms at tanh 10).
      sketchybar "''${args[@]}"
    '';
  };

  frontAppPlugin = pkgs.writeShellApplication {
    name = "sketchybar-front-app";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      # $INFO carries the application name on front_app_switched.
      sketchybar --set "$NAME" label="''${INFO:-}" icon="$('${appFont}' "''${INFO:-}")"
    '';
  };

  clockPlugin = pkgs.writeShellApplication {
    name = "sketchybar-clock";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      # Reference-setup calendar: textual date in the icon slot, time in the
      # label. No SF Symbols clock glyph exists in the recipe.
      sketchybar --set "$NAME" icon="$(date '+%a %d %b')" label="$(date '+%H:%M')"
    '';
  };

  batteryPlugin = pkgs.writeShellApplication {
    name = "sketchybar-battery";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      # SF Symbols battery glyphs, byte-exact from the reference setup.
      status=$(/usr/bin/pmset -g batt)
      percent=$(printf '%s' "$status" | /usr/bin/grep -oE '[0-9]+%' | head -1)
      charge=''${percent%"%"}
      color=${colorLabel}
      if printf '%s' "$status" | /usr/bin/grep -q 'AC Power'; then
        icon=$(printf '\xf4\x80\xa2\x8b')
      elif [ "''${charge:-0}" -gt 80 ]; then
        icon=$(printf '\xf4\x80\x9b\xa8')
      elif [ "''${charge:-0}" -gt 60 ]; then
        icon=$(printf '\xf4\x80\xba\xb8')
      elif [ "''${charge:-0}" -gt 40 ]; then
        icon=$(printf '\xf4\x80\xba\xb6')
      elif [ "''${charge:-0}" -gt 20 ]; then
        icon=$(printf '\xf4\x80\x9b\xa9'); color=${colorWarn}
      else
        icon=$(printf '\xf4\x80\x9b\xaa'); color=${colorCrit}
      fi
      sketchybar --set "$NAME" icon="$icon" icon.color="$color" label="$percent"
    '';
  };

  # Space items are passive click targets; spacesPlugin is their only writer.
  # Numbers sit in the icon slot, per-Space app icons in the label slot. The
  # accent lives here statically as highlight_color.
  spaceItems = lib.concatMapStrings (index: ''
    sketchybar --add space space.${index} left \
      --set space.${index} space=${index} drawing=off \
        icon=${index} icon.padding_left=12 icon.padding_right=6 \
        icon.color=${colorLabel} icon.highlight_color=${colorAccent} \
        label.font="sketchybar-app-font:Regular:16.0" label.y_offset=-1 \
        label.padding_right=14 label.color=${colorGray2} label.highlight_color=${colorLabel} \
        background.color=${colorGray1} background.border_width=1 \
        background.height=26 background.corner_radius=9 background.border_color=${colorGray2} \
        padding_left=2 padding_right=2 \
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

      # The bar floats at the top edge with a y offset; the native menu bar
      # auto-hides (reachable by mousing to the top). Reserve the bar's full
      # vertical footprint -- height plus offset -- so tiles never underlap it;
      # the check pins this equality.
      external_bar = "all:${toString (barHeight + barYOffset)}:0";
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
      sketchybar --bar position=top height=${toString barHeight} color=${colorBarBg} \
        margin=12 y_offset=${toString barYOffset} corner_radius=12 blur_radius=30 \
        padding_left=6 padding_right=6

      sketchybar --default \
        icon.font="SF Pro:Bold:14.0" icon.color=${colorLabel} \
        icon.padding_left=3 icon.padding_right=3 \
        label.font="SF Pro:Semibold:13.0" label.color=${colorLabel} \
        label.padding_left=3 label.padding_right=3 \
        padding_left=5 padding_right=5 \
        background.height=28 background.corner_radius=9 \
        background.border_width=2 background.border_color=${colorGray2} \
        background.drawing=off

      sketchybar --add item apple_logo left \
        --set apple_logo icon="$(printf '\xf4\x80\xa3\xba')" icon.font="SF Pro:Black:16.0" \
          icon.color=${colorAccent} icon.padding_left=10 icon.padding_right=10 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorEdge} \
          click_script='open -a "Mission Control"'

      ${spaceItems}
      sketchybar --add item spaces_chevron left \
        --set spaces_chevron icon="$(printf '\xf4\x80\x86\x8a')" icon.font="SF Pro:Bold:12.0" \
          icon.color=${colorGray2} padding_left=4 padding_right=2

      sketchybar --add item front_app left \
        --set front_app icon.font="sketchybar-app-font:Regular:16.0" \
          label.font="SF Pro:Black:12.0" label.padding_left=6 padding_left=10 \
          script='${lib.getExe frontAppPlugin}' \
        --subscribe front_app front_app_switched

      sketchybar --add item clock right \
        --set clock update_freq=30 \
          icon.font="SF Pro:Black:12.0" icon.padding_left=10 \
          label.padding_right=10 \
          background.drawing=on background.color=${colorGray2} \
          background.border_width=1 background.border_color=${colorEdge} \
          script='${lib.getExe clockPlugin}'

      sketchybar --add item battery right \
        --set battery update_freq=120 \
          icon.font="SF Pro:Regular:19.0" icon.padding_left=8 \
          label.padding_right=8 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorEdge} \
          script='${lib.getExe batteryPlugin}' \
        --subscribe battery power_source_change system_woke

      sketchybar --add item spaces_driver left \
        --set spaces_driver drawing=off script='${lib.getExe spacesPlugin}' \
        --subscribe spaces_driver space_change space_windows_change display_change

      sketchybar --add event space_eager
      sketchybar --add item eager_driver left \
        --set eager_driver drawing=off script='${lib.getExe spacesEagerPlugin}' \
        --subscribe eager_driver space_eager

      # Populate initial state without waiting for the first events. The
      # plugins address their item through $NAME, which events normally set.
      ${lib.getExe spacesPlugin}
      NAME=battery ${lib.getExe batteryPlugin}
      NAME=clock ${lib.getExe clockPlugin}

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
