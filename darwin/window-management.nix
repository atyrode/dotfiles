{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;

  # Design tokens, spec v2 (pixel-audited 2026-08-09). Roles, not values:
  # exactly two surfaces (capsule fill, clock fill doubling as border tone),
  # one primary text color, one DEDICATED secondary-text color -- the v1 bar
  # reused the surface gray for dim text, which dimmed inactive Space icons to
  # invisibility -- and the Rio vi-cursor accent reserved exclusively for
  # focused state. Structure allows two levels only: bar surface -> capsule.
  # Every visible element sits in a capsule; nothing floats bare.
  barHeight = 40;
  barYOffset = 8;
  colorBarBg = "0xf0282c34";
  colorLabel = "0xffffffff";
  colorTextDim = "0xff9aa3b2";
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
      # Apps the font does not know map to ":default:", a solid white box that
      # reads as tofu (pixel audit) -- unmapped apps get no ligature instead.
      declare -A seen
      while IFS=$'\t' read -r space app; do
        key="$space::$app"
        [ -n "''${seen[$key]:-}" ] && continue
        seen[$key]=1
        glyph=$('${appFont}' "$app")
        case $glyph in
          *:default:*) continue ;;
        esac
        icons[$space]="''${icons[$space]:-}$glyph "
      done < <(yabai -m query --windows | jq -r '.[] | select(."is-minimized" | not) | "\(.space)\t\(.app)"')

      # Focused Space: accent numeral + edge ring; app icons stay visible on
      # every Space (the reference setup's width-collapse was rejected by the
      # operator). Doc order semantics: sets BEFORE --animate snap (booleans,
      # strings), sets AFTER it fade (colors).
      snap=()
      fade=()
      for index in 1 2 3 4 5 6 7 8 9; do
        if [ -z "''${count[$index]:-}" ]; then
          snap+=(--set "space.$index" drawing=off)
          continue
        fi
        if [ "''${focus[$index]}" = "true" ]; then
          highlight=on
          edge=${colorEdge}
        else
          highlight=off
          edge=${colorGray2}
        fi
        snap+=(
          --set "space.$index" drawing=on
          "icon.highlight=$highlight" "label.highlight=$highlight"
          label="''${icons[$index]:-}" label.width=dynamic
        )
        fade+=(
          --set "space.$index"
          "background.border_color=$edge"
        )
      done
      sketchybar "''${snap[@]}" --animate tanh 20 "''${fade[@]}"
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
      snap=()
      fade=()
      for index in 1 2 3 4 5 6 7 8 9; do
        if [ "$index" = "$target" ]; then
          highlight=on
          edge=${colorEdge}
        else
          highlight=off
          edge=${colorGray2}
        fi
        snap+=(
          --set "space.$index"
          "icon.highlight=$highlight" "label.highlight=$highlight"
        )
        fade+=(
          --set "space.$index"
          "background.border_color=$edge"
        )
      done
      # Booleans snap before --animate (they would otherwise commit at the
      # END of the animation window, re-adding the lag this path removes);
      # colors fade after it. Single message, doc-verified order.
      sketchybar "''${snap[@]}" --animate tanh 20 "''${fade[@]}"
    '';
  };

  frontAppPlugin = pkgs.writeShellApplication {
    name = "sketchybar-front-app";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      # $INFO carries the application name on front_app_switched.
      # Unmapped apps produce the ":default:" white-box ligature; show text
      # only for those instead of a tofu tile.
      glyph=$('${appFont}' "''${INFO:-}")
      case $glyph in
        *:default:*) sketchybar --set "$NAME" label="''${INFO:-}" icon="" ;;
        *) sketchybar --set "$NAME" label="''${INFO:-}" icon="$glyph" ;;
      esac
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

  volumePlugin = pkgs.writeShellApplication {
    name = "sketchybar-volume";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      # $INFO carries the volume percentage on volume_change, a native
      # SketchyBar event. SF Symbols speaker glyphs from the reference setup.
      # volume_change delivers the percentage in $INFO; other senders (the
      # unlock event, initial run) re-query the system instead.
      if [ "''${SENDER:-}" = "volume_change" ]; then
        volume=''${INFO:-0}
      else
        volume=$(/usr/bin/osascript -e 'output volume of (get volume settings)')
      fi
      if [ "$volume" -ge 60 ]; then
        icon=$(printf '\xf4\x80\x8a\xa9')
      elif [ "$volume" -ge 30 ]; then
        icon=$(printf '\xf4\x80\x8a\xa7')
      elif [ "$volume" -ge 10 ]; then
        icon=$(printf '\xf4\x80\x8a\xa5')
      elif [ "$volume" -gt 0 ]; then
        icon=$(printf '\xf4\x80\x8a\xa1')
      else
        icon=$(printf '\xf4\x80\x8a\xa3')
      fi
      sketchybar --set "$NAME" icon="$icon" label="$volume%"
    '';
  };

  # FelixKratz's hover-popup pattern (dotfiles@e6288b3 items/github.sh):
  # mouse.entered opens, mouse.exited and mouse.exited.global close. The
  # daemon swallows exits that land inside the item's own popup, so the menu
  # stays open while the pointer is over it.
  hoverPopupPlugin = pkgs.writeShellApplication {
    name = "sketchybar-hover-popup";
    runtimeInputs = [ pkgs.sketchybar ];
    text = ''
      case "''${SENDER:-}" in
        mouse.entered) sketchybar --set "$NAME" popup.drawing=on ;;
        mouse.exited | mouse.exited.global) sketchybar --set "$NAME" popup.drawing=off ;;
      esac
    '';
  };

  weatherPlugin = pkgs.writeShellApplication {
    name = "sketchybar-weather";
    runtimeInputs = [
      pkgs.sketchybar
      pkgs.curl
    ];
    text = ''
      # Weather has no native event, so this is one of the three sanctioned
      # timers (clock, battery percentage, weather). wttr.in needs no API key
      # and locates by IP; on failure the previous label is simply kept.
      # Text-only on purpose: wttr's %c is a color emoji, which reads as a
      # placeholder next to the bar's monochrome SF glyphs (pixel audit).
      report=$(curl -fsS --max-time 5 'https://wttr.in/?format=%t' || true)
      case $report in
        *"Unknown location"*|"") exit 0 ;;
      esac
      report=''${report#+}
      report=''${report%C}
      sketchybar --set "$NAME" label="$report"
    '';
  };

  # Space items are passive click targets; spacesPlugin is their only writer.
  # Numbers sit in the icon slot, per-Space app icons in the label slot. The
  # accent lives here statically as highlight_color.
  spaceItems = lib.concatMapStrings (index: ''
    sketchybar --add space space.${index} left \
      --set space.${index} space=${index} drawing=off \
        icon=${index} icon.padding_left=8 icon.padding_right=6 \
        icon.font="SF Pro:Bold:14.0" \
        icon.color=${colorLabel} icon.highlight_color=${colorAccent} \
        label.font="sketchybar-app-font:Regular:16.0" label.y_offset=-1 \
        label.padding_right=8 label.color=${colorTextDim} label.highlight_color=${colorLabel} \
        background.drawing=on background.color=${colorGray1} background.border_width=1 \
        background.height=28 background.corner_radius=9 background.border_color=${colorGray2} \
        padding_left=3 padding_right=3 \
        click_script='${yabai} -m space --focus ${index} && sketchybar --trigger space_eager TARGET=${index}'
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
      sketchybar --bar position=top height=${toString barHeight} y_offset=${toString barYOffset} color=${colorBarBg} \
        margin=12 corner_radius=12 blur_radius=30 \
        sticky=on shadow=on \
        padding_left=8 padding_right=8

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
          icon.color=${colorLabel} icon.padding_left=10 icon.padding_right=9 icon.y_offset=1 \
          padding_left=3 padding_right=3 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorEdge} \
          popup.background.color=${colorBarBg} popup.background.corner_radius=9 \
          popup.background.border_width=2 popup.background.border_color=${colorGray2} \
          popup.blur_radius=30 popup.height=30 \
          script='${lib.getExe hoverPopupPlugin}' \
          click_script='sketchybar --set apple_logo popup.drawing=toggle' \
        --subscribe apple_logo mouse.entered mouse.exited mouse.exited.global

      sketchybar --add item apple.settings popup.apple_logo \
        --set apple.settings label="Settings" \
          click_script='open -a "System Settings"; sketchybar --set apple_logo popup.drawing=off'
      sketchybar --add item apple.activity popup.apple_logo \
        --set apple.activity label="Activity" \
          click_script='open -a "Activity Monitor"; sketchybar --set apple_logo popup.drawing=off'
      sketchybar --add item apple.lock popup.apple_logo \
        --set apple.lock label="Lock Screen" \
          click_script='pmset displaysleepnow; sketchybar --set apple_logo popup.drawing=off'

      ${spaceItems}
      sketchybar --add item front_app left \
        --set front_app icon.font="sketchybar-app-font:Regular:16.0" \
          icon.padding_left=8 icon.color=${colorLabel} \
          label.font="SF Pro:Semibold:13.0" label.padding_left=4 label.padding_right=8 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorGray2} \
          background.height=28 background.corner_radius=9 \
          padding_left=3 padding_right=3 \
          script='${lib.getExe frontAppPlugin}' \
        --subscribe front_app front_app_switched

      sketchybar --add item clock right \
        --set clock update_freq=30 \
          icon.font="SF Pro:Semibold:13.0" icon.padding_left=8 \
          label.font="SF Pro:Bold:13.0" label.padding_right=8 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorGray2} \
          background.height=28 background.corner_radius=9 \
          padding_left=3 padding_right=3 \
          script='${lib.getExe clockPlugin}' \
          click_script='open -a Calendar'

      sketchybar --add item battery right \
        --set battery update_freq=120 \
          icon.font="SF Pro:Regular:16.0" icon.padding_left=8 \
          label.padding_right=8 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorGray2} \
          background.height=28 background.corner_radius=9 \
          padding_left=3 padding_right=3 \
          script='${lib.getExe batteryPlugin}' \
          click_script='open "x-apple.systempreferences:com.apple.Battery-Settings.extension"' \
        --subscribe battery power_source_change system_woke

      sketchybar --add item volume right \
        --set volume icon.font="SF Pro:Regular:14.0" icon.padding_left=8 \
          label.padding_right=8 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorGray2} \
          background.height=28 background.corner_radius=9 \
          padding_left=3 padding_right=3 \
          script='${lib.getExe volumePlugin}' \
          click_script='open "x-apple.systempreferences:com.apple.Sound-Settings.extension"' \
        --subscribe volume volume_change

      sketchybar --add item weather right \
        --set weather update_freq=1800 label.padding_left=8 label.padding_right=8 \
          background.drawing=on background.color=${colorGray1} \
          background.border_width=1 background.border_color=${colorGray2} \
          background.height=28 background.corner_radius=9 \
          padding_left=3 padding_right=3 \
          script='${lib.getExe weatherPlugin}' \
          click_script='open "https://wttr.in"' \
        --subscribe weather system_woke

      sketchybar --add item spaces_driver left \
        --set spaces_driver drawing=off script='${lib.getExe spacesPlugin}' \
        --subscribe spaces_driver space_change space_windows_change display_change

      sketchybar --add event space_eager
      sketchybar --add item eager_driver left \
        --set eager_driver drawing=off script='${lib.getExe spacesEagerPlugin}' \
        --subscribe eager_driver space_eager

      # Push-driven freshness after unlock (docs: custom events can bind an
      # NSDistributedNotification). Clock, battery, volume and weather refresh
      # the moment the screen unlocks instead of waiting for their timers.
      sketchybar --add event screen_unlocked com.apple.screenIsUnlocked \
        --subscribe clock screen_unlocked \
        --subscribe battery screen_unlocked \
        --subscribe volume screen_unlocked \
        --subscribe weather screen_unlocked

      # Populate initial state without waiting for the first events. The
      # plugins address their item through $NAME, which events normally set.
      ${lib.getExe spacesPlugin}
      NAME=battery ${lib.getExe batteryPlugin}
      NAME=clock ${lib.getExe clockPlugin}
      NAME=volume INFO="$(/usr/bin/osascript -e 'output volume of (get volume settings)')" ${lib.getExe volumePlugin}
      NAME=front_app INFO="$(${yabai} -m query --windows --window 2>/dev/null | ${lib.getExe pkgs.jq} -r '.app // empty')" ${lib.getExe frontAppPlugin}

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
