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

  # JankyBorders only renders focus. Its one cross-component contract is the
  # shared palette: the active border accent must be the same teal Rio already
  # uses for its vi cursor, otherwise "settled shared colors" silently drifts
  # into two ad-hoc palettes. Rio's config is a literal TOML artifact, so the
  # accent is read from it rather than duplicated here.
  borders = homeConfig.config.services.jankyborders;
  bordersWidth = borders.settings.width or 0;
  bordersActive = lib.toLower (borders.settings.active_color or "");
  bordersInactive = lib.toLower (borders.settings.inactive_color or "");
  isArgbColor = color: builtins.match "^0x[0-9a-f]{8}$" color != null;
  rioViCursor =
    let
      matches = builtins.match ".*vi-cursor = \"#([0-9A-Fa-f]{6})\".*" (
        builtins.readFile ../home/rio/config.toml
      );
    in
    if matches == null then null else lib.toLower (lib.head matches);

  # The solo-window suppression only works if every visibility-changing event
  # re-runs the script; a missing signal leaves a stale border state behind.
  bordersSoloEvents = [
    "window_created"
    "window_destroyed"
    "window_focused"
    "window_minimized"
    "window_deminimized"
    "space_changed"
    "display_changed"
  ];
  yabaiExtraConfig = cfg.services.yabai.extraConfig;
  missingSoloSignals = lib.filter (
    event: !(lib.hasInfix "label=borders-solo-${event} event=${event}" yabaiExtraConfig)
  ) bordersSoloEvents;

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
assert lib.assertMsg borders.enable
  "the desktop capability must enable JankyBorders to render focus";
assert lib.assertMsg (bordersWidth > 0) "JankyBorders must declare a positive border width";
assert lib.assertMsg (isArgbColor bordersActive && isArgbColor bordersInactive) (
  "JankyBorders colors must be 0xaarrggbb literals; got active="
  + bordersActive
  + " inactive="
  + bordersInactive
);
assert lib.assertMsg (
  bordersActive != bordersInactive
) "JankyBorders active and inactive colors must differ, or the border cannot communicate focus";
assert lib.assertMsg (rioViCursor != null)
  "could not read the vi-cursor accent from home/rio/config.toml; the shared-palette contract needs it";
assert lib.assertMsg (bordersActive == "0xff${rioViCursor}") (
  "the active border accent must reuse Rio's vi-cursor #"
  + rioViCursor
  + " so the stack keeps one palette; got "
  + bordersActive
);
assert lib.assertMsg (missingSoloSignals == [ ]) (
  "yabai must register a borders-solo signal for every visibility-changing event, or a"
  + " lone window keeps a stale border; missing: "
  + lib.concatStringsSep ", " missingSoloSignals
);
pkgs.runCommand "check-window-management-${pkgs.system}" { } ''
  mkdir "$out"
''
