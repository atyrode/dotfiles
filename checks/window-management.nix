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

  # JankyBorders was evaluated as Phase 3 and removed by operator decision
  # (2026-08-08): reactive solo-window hiding cannot be flash-free because
  # border windows are composited on the target Space before any signal fires,
  # and an always-on border was judged visually heavy. Guard the removal so a
  # future phase reintroduces it deliberately rather than by leftover config.
  bordersEnabled = homeConfig.config.services.jankyborders.enable;
  yabaiExtraConfig = cfg.services.yabai.extraConfig;
  strayBordersSignals = lib.hasInfix "borders-solo" yabaiExtraConfig;

  # SketchyBar runs the Lua redesign (SbarLua runtime, neutonfoo chip
  # language, Rio palette) committed as the sketchybar-lua tree;
  # services.sketchybar.config stays empty so the daemon boots the deployed
  # tree's own sketchybarrc. The contracts therefore read the tree itself.
  sketchybarEnabled = cfg.services.sketchybar.enable;
  sketchybarInlineConfig = cfg.services.sketchybar.config;
  barTreeDir = ../darwin/window-management/sketchybar-lua;
  barInit = builtins.readFile (barTreeDir + "/init.lua");
  barSettings = builtins.readFile (barTreeDir + "/settings.lua");
  barColors = builtins.readFile (barTreeDir + "/colors.lua");
  barSpacesItem = builtins.readFile (barTreeDir + "/items/spaces.lua");
  barTreeText =
    barInit
    + barSettings
    + lib.concatMapStrings (file: builtins.readFile (barTreeDir + "/items/${file}")) [
      "spaces.lua"
      "weather.lua"
      "spotify.lua"
      "clock.lua"
      "battery.lua"
      "volume.lua"
    ];

  # The bar is a transparent full-width strip with no y offset, so yabai must
  # reserve exactly the bar height declared in settings.lua.
  barHeightMatch = builtins.match ".*bar_height = ([0-9]+),.*" barSettings;
  barFootprint = if barHeightMatch == null then null else lib.head barHeightMatch;
  externalBar = cfg.services.yabai.config.external_bar or "";

  # Keyboard Space switches must announce their destination eagerly: macOS
  # emits space_change only when the slide animation commits, so a binding
  # without the trigger regresses the bar highlight to trailing the keypress
  # by the whole animation. Both halves are pinned: the skhd bindings fire the
  # event, and the Lua tree registers and handles it.
  bindingsMissingEagerTrigger = lib.filter (
    index:
    !(lib.hasInfix "--focus ${index} && sketchybar --trigger space_eager TARGET=${index}" skhdConfig)
  ) (map toString (lib.range 1 9));
  treeHandlesEager =
    lib.hasInfix ''sbar.add("event", "space_eager")'' barSpacesItem
    && lib.hasInfix ''subscribe("space_eager"'' barSpacesItem;

  # Space chips must never hide their app-icon content: the operator rejected
  # the reference collapse twice. The chip styler may only touch colors, and
  # nothing in the tree may zero a label width or animate one away.
  spacesCollapseRegression = lib.filter (needle: lib.hasInfix needle barSpacesItem) [
    "width = 0"
    "width=0"
    "--animate"
    "label.drawing"
  ];

  # Exclusions that must hold: the deprecated media_change event class (dead
  # on macOS 26; Spotify rides its own distributed notification instead) and
  # wifi_change (broken since Sonoma) stay out of the tree.
  forbiddenBarEvents = lib.filter (event: lib.hasInfix event barTreeText) [
    "wifi_change"
    "media_change"
  ];
  requiredBarEvents = [
    "power_source_change"
    "system_woke"
    "volume_change"
    "window_focus"
    "windows_on_spaces"
    "com.spotify.client.PlaybackStateChanged"
  ];
  missingBarEvents = lib.filter (event: !(lib.hasInfix event barTreeText)) requiredBarEvents;

  # Palette pin: chips carry the Rio theme -- the teal accent from
  # home/rio/config.toml and the terminal background as text-on-accent.
  portPaletteIntact =
    lib.hasInfix "accent = 0xff70c0b1" barColors && lib.hasInfix "on_accent = 0xff282c34" barColors;

  # yabai must feed the two custom events the ported tree consumes.
  missingBarSignals = lib.filter (trigger: !(lib.hasInfix trigger cfg.services.yabai.extraConfig)) [
    "--trigger window_focus"
    "--trigger windows_on_spaces"
  ];

  # skhd.zig resolves a character key literal through
  # TISCopyCurrentASCIICapableKeyboardLayoutInputSource + UCKeyTranslate, so a
  # literal only parses when the active layout emits that character unshifted.
  # This workstation runs French AZERTY, whose unshifted number row is
  # & é " ' ( § è ! ç à -- "cmd - 1" therefore aborts the entire config with
  # `Unknown key '1'` and skhd exits 1 in a launchd crash loop. Number-row keys
  # must be addressed by layout-independent virtual keycode instead.
  #
  # Carbon kVK_ANSI_<n>, verified against Carbon.framework on an arm64 Mac.
  spaceKeycodes = {
    "1" = "0x12";
    "2" = "0x13";
    "3" = "0x14";
    "4" = "0x15";
    "5" = "0x17";
    "6" = "0x16";
    "7" = "0x1A";
    "8" = "0x1C";
    "9" = "0x19";
  };

  # Every hotkey line is "<chord> - <key> : <cmd>" or "<chord> - <key> ; <mode>".
  # The key is the last token left of the first ":" or ";".
  configLines = lib.splitString "\n" skhdConfig;
  isBindingLine =
    line:
    line != ""
    && !(lib.hasPrefix "#" line)
    && !(lib.hasPrefix "::" line)
    && builtins.match "^[^:;]*[:;].*$" line != null;
  tokensOf = text: lib.filter (token: token != "") (lib.splitString " " text);
  keyTokenOf =
    line:
    let
      tokens = tokensOf (lib.head (builtins.match "^([^:;]*)[:;].*$" line));
    in
    if tokens == [ ] then null else lib.last tokens;
  keyTokens = lib.filter (token: token != null) (
    map keyTokenOf (lib.filter isBindingLine configLines)
  );

  # Named keys skhd.zig resolves identically across the layouts in use here.
  # Anything else must be a hex keycode.
  layoutSafeNamedKeys = [
    "h"
    "j"
    "k"
    "l"
    "f"
    "b"
    "r"
    "space"
    "escape"
    "return"
    # Arrows carry no character, so no layout can move or remove them.
    "left"
    "down"
    "up"
    "right"
  ];
  isHexKeycode = token: builtins.match "^0x[0-9A-Fa-f]+$" token != null;
  digitLiteralKeys = lib.filter (token: builtins.match "^[0-9]$" token != null) keyTokens;
  unsupportedKeys = lib.filter (
    token: !(lib.elem token layoutSafeNamedKeys) && !(isHexKeycode token)
  ) keyTokens;

  requiredBindings = [
    "ctrl + alt + cmd - h : yabai -m window --focus west"
    "ctrl + alt + cmd + shift - l : yabai -m window --warp east"
    "ctrl + alt + cmd - space : yabai -m window --toggle float"
    "ctrl + alt + cmd - f : yabai -m window --toggle zoom-fullscreen"
    "ctrl + alt + cmd - b : yabai -m space --balance"
    "ctrl + alt + cmd - r ; resize"
    "resize < escape ; default"
  ]
  # Every vim direction has an arrow alias bound to the identical action, so a
  # hand arriving from Windows is never told a key "does nothing". Pinning both
  # halves keeps them from drifting apart into two different models.
  ++
    lib.concatMap
      (direction: [
        "ctrl + alt + cmd - ${direction.arrow} : yabai -m window --focus ${direction.edge}"
        "ctrl + alt + cmd - ${direction.vim} : yabai -m window --focus ${direction.edge}"
        "ctrl + alt + cmd + shift - ${direction.arrow} : yabai -m window --warp ${direction.edge}"
        "ctrl + alt + cmd + shift - ${direction.vim} : yabai -m window --warp ${direction.edge}"
      ])
      [
        {
          vim = "h";
          arrow = "left";
          edge = "west";
        }
        {
          vim = "j";
          arrow = "down";
          edge = "south";
        }
        {
          vim = "k";
          arrow = "up";
          edge = "north";
        }
        {
          vim = "l";
          arrow = "right";
          edge = "east";
        }
      ]
  ++ lib.concatMap (index: [
    "ctrl + alt + cmd - ${spaceKeycodes.${index}} : yabai -m space --focus ${index}"
    "ctrl + alt + cmd + shift - ${spaceKeycodes.${index}} : yabai -m window --space ${index} && yabai -m space --focus ${index}"
  ]) (builtins.attrNames spaceKeycodes);
  missingBindings = lib.filter (binding: !(lib.hasInfix binding skhdConfig)) requiredBindings;

  # Karabiner owns input transformation only. Its whole job in this stack is to
  # synthesise the exact chord skhd binds, so assert that correspondence rather
  # than the literal JSON: if either side is retuned independently, every
  # leader binding silently stops firing.
  karabiner = builtins.fromJSON (builtins.readFile ../home/macos-window-management/karabiner.json);
  karabinerProfiles = karabiner.profiles;
  karabinerRules = lib.concatMap (
    profile: profile.complex_modifications.rules or [ ]
  ) karabinerProfiles;
  karabinerManipulators = lib.concatMap (rule: rule.manipulators) karabinerRules;
  capsManipulators = lib.filter (
    manipulator: (manipulator.from.key_code or null) == "caps_lock"
  ) karabinerManipulators;
  capsManipulator = lib.head capsManipulators;

  # Karabiner presents a virtual keyboard to macOS. When its type is unset,
  # macOS cannot identify it and reruns the Keyboard Setup Assistant. Karabiner
  # then persists the answer by rewriting karabiner.json, so leaving this out of
  # the managed file means every activation reverts it and the assistant returns.
  # This workstation's built-in keyboard is ISO: kVK_ISO_Section resolves to a
  # real character, which has no equivalent on ANSI.
  keyboardTypes = map (
    profile: profile.virtual_hid_keyboard.keyboard_type_v2 or ""
  ) karabinerProfiles;
  untypedProfiles = lib.filter (keyboardType: keyboardType == "") keyboardTypes;

  # The karabiner-elements cask is `auto_updates`, so the application updates
  # itself outside Homebrew and outside this flake. An unattended bump can carry
  # a new DriverKit extension version, which macOS makes the operator re-approve
  # before Karabiner is back in the event path. That presents as Caps Lock
  # silently no longer producing the leader, which is indistinguishable from an
  # skhd or yabai fault. Pin the declared cask version by disabling the
  # application's own updater.
  karabinerChecksForUpdates = karabiner.global.check_for_updates_on_startup or true;

  # skhd's chord, expressed as the Karabiner key_codes that must reach it.
  leaderModifiers = [
    "left_command"
    "left_control"
    "left_option"
  ];
  capsEmits =
    let
      inherit (capsManipulator) to;
      event = lib.head to;
    in
    lib.sort (a: b: a < b) ([ event.key_code ] ++ (event.modifiers or [ ]));

  # Caps Lock is deliberately leader-only. Tap-to-Escape is the conventional
  # pairing, but it is only worth its cost under modal editing, which this
  # workstation does not use, and a stray Escape dismisses dialogs and TUI
  # prompts. Adding `to_if_alone` back is a one-key change if that ever shifts.
  capsTapEmits = map (event: event.key_code) (capsManipulator.to_if_alone or [ ]);

  # Upstream parses `parameters` on a manipulator or profile-wide, and silently
  # ignores a rule-level one as an unknown key, so a tap timeout placed on the
  # rule never takes effect.
  rulesWithMisplacedParameters = lib.filter (rule: rule ? parameters) karabinerRules;
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
assert lib.assertMsg (digitLiteralKeys == [ ]) (
  "skhd binds the layout-dependent number-row characters "
  + lib.concatStringsSep ", " digitLiteralKeys
  + ". skhd.zig resolves character literals through the active keyboard layout, and the "
  + "French AZERTY layout on this workstation emits no unshifted digit, so the daemon aborts "
  + "the whole config with `Unknown key`. Use the kVK_ANSI keycodes instead."
);
assert lib.assertMsg (unsupportedKeys == [ ]) (
  "skhd binds keys that are neither layout-safe named keys nor hex keycodes: "
  + lib.concatStringsSep ", " unsupportedKeys
);
assert lib.assertMsg (keyTokens != [ ]) "the skhd binding parser contract matched no hotkey lines";
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
assert lib.assertMsg (builtins.elem "karabiner-elements" caskNames)
  "nix-homebrew must install Karabiner-Elements, which owns the Caps Lock leader";
assert lib.assertMsg
  (builtins.length karabinerProfiles == 1 && (lib.head karabinerProfiles).selected)
  "Karabiner must ship exactly one selected profile: switching profiles rewrites karabiner.json and would clobber the managed configuration";
assert lib.assertMsg (
  builtins.length capsManipulators == 1
) "Karabiner must define exactly one caps_lock manipulator";
assert lib.assertMsg ((capsManipulator.type or null) == "basic")
  "the caps_lock manipulator must declare \"type\": \"basic\"; Karabiner refuses to load a manipulator without an explicit type";
assert lib.assertMsg (builtins.elem "any" (capsManipulator.from.modifiers.optional or [ ]))
  "the caps_lock manipulator must allow any optional modifier, otherwise the leader stops matching as soon as Shift is held and every send-to-Space binding dies";
assert lib.assertMsg (capsEmits == leaderModifiers) (
  "Karabiner's held Caps Lock must emit exactly the chord skhd binds ("
  + lib.concatStringsSep " + " leaderModifiers
  + ") but it emits "
  + lib.concatStringsSep " + " capsEmits
);
assert lib.assertMsg (capsTapEmits == [ ]) (
  "Caps Lock is leader-only on this workstation, but tapping it emits "
  + lib.concatStringsSep ", " capsTapEmits
  + ". A tap action fires on every leader press that turns out not to be a chord, which"
  + " dismisses dialogs and TUI prompts. Reintroduce `to_if_alone` only alongside a"
  + " deliberate basic.to_if_alone_timeout_milliseconds."
);
assert lib.assertMsg (untypedProfiles == [ ]) (
  "every Karabiner profile must pin virtual_hid_keyboard.keyboard_type_v2."
  + " An unset type leaves macOS unable to identify Karabiner's virtual keyboard,"
  + " so it reruns the Keyboard Setup Assistant. Karabiner persists the answer by"
  + " rewriting karabiner.json, which the next activation reverts, making the"
  + " assistant reappear on a loop."
);
assert lib.assertMsg (!karabinerChecksForUpdates) (
  "Karabiner must not check for updates on startup. The cask is `auto_updates`, so the"
  + " application would update itself outside this flake, and a new DriverKit extension"
  + " version needs operator re-approval before Karabiner is back in the event path."
  + " That presents as Caps Lock silently no longer producing the leader."
);
assert lib.assertMsg (rulesWithMisplacedParameters == [ ]) (
  "Karabiner parses `parameters` on a manipulator or profile-wide and silently ignores a rule-level one, so these rules have a tap timeout that never takes effect: "
  + lib.concatStringsSep ", " (
    map (rule: rule.description or "<undescribed>") rulesWithMisplacedParameters
  )
);
assert lib.assertMsg (!bordersEnabled)
  "JankyBorders was removed by operator decision (2026-08-08): reactive solo-window hiding cannot be flash-free and an always-on border was judged visually heavy. Reintroduce it as a deliberate phase, not leftover config";
assert lib.assertMsg (
  !strayBordersSignals
) "yabai still registers borders-solo signals although JankyBorders was removed";
assert lib.assertMsg sketchybarEnabled "the Darwin workstation must enable SketchyBar (phase 4)";
assert lib.assertMsg (sketchybarInlineConfig == "")
  "SketchyBar must boot the deployed Lua tree from ~/.config/sketchybar; an inline config would shadow it";
assert lib.assertMsg (barFootprint != null) "could not parse bar_height out of settings.lua";
assert lib.assertMsg (externalBar == "all:${barFootprint}:0") (
  "yabai must reserve exactly the bar height at the top edge:"
  + " expected external_bar all:"
  + barFootprint
  + ":0 but found '"
  + externalBar
  + "'. A mismatch either hides the bar behind tiles or wastes screen"
);
assert lib.assertMsg (lib.hasInfix ''position = "top"'' barInit)
  "the bar owns the top edge; moving it requires flipping the external_bar reservation and the menu-bar policy together";
assert lib.assertMsg cfg.system.defaults.NSGlobalDomain._HIHideMenuBar
  "a top-positioned SketchyBar requires the native menu bar to auto-hide, or the two bars stack";
assert lib.assertMsg (bindingsMissingEagerTrigger == [ ]) (
  "these Space-focus bindings do not announce their destination through the space_eager"
  + " trigger, so the bar highlight trails the keypress by the whole switch animation: "
  + lib.concatStringsSep ", " bindingsMissingEagerTrigger
);
assert lib.assertMsg treeHandlesEager
  "spaces.lua must register the space_eager event and subscribe to it; without it the keyboard bindings' announcements go nowhere";
assert lib.assertMsg (spacesCollapseRegression == [ ]) (
  "Space chips must keep their app-icon content visible at all times -- the operator rejected"
  + " collapse/animation styling twice; offending constructs in spaces.lua: "
  + lib.concatStringsSep ", " spacesCollapseRegression
);
assert lib.assertMsg (missingBarEvents == [ ]) (
  "the Lua tree lost required event subscriptions: " + lib.concatStringsSep ", " missingBarEvents
);
assert lib.assertMsg (forbiddenBarEvents == [ ]) (
  "the Lua tree subscribes to events broken or deprecated on this macOS: "
  + lib.concatStringsSep ", " forbiddenBarEvents
);
assert lib.assertMsg portPaletteIntact
  "colors.lua must carry the Rio theme: accent 0xff70c0b1 (vi-cursor teal) with 0xff282c34 text-on-accent; the bar and the terminal share one palette";
assert lib.assertMsg (missingBarSignals == [ ]) (
  "yabai must feed the ported tree's custom events; missing signal actions: "
  + lib.concatStringsSep ", " missingBarSignals
);
pkgs.runCommand "check-window-management-${pkgs.system}" { } ''
  mkdir "$out"
''
