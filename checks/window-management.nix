{
  darwinConfig,
  homeConfig,
  lib,
  pkgs,
}:

let
  cfg = darwinConfig.config;
  darwinWindowManagementSource = builtins.readFile ../darwin/window-management.nix;
  packageNames = map lib.getName homeConfig.config.home.packages;
  caskName = cask: if builtins.isString cask then cask else cask.name;
  caskNames = map caskName cfg.homebrew.casks;
  skhdConfig = cfg.environment.etc.skhdrc.text;
  skhdArguments = cfg.launchd.user.agents.skhd.serviceConfig.ProgramArguments;
  managedRestart = homeConfig.config.home.activation.restartManagedDesktopConsumers;
  managedRestartText = builtins.unsafeDiscardStringContext managedRestart.data;
  managedRestartNeedles = [
    "if [[ -v DRY_RUN ]]; then"
    ''user_domain="gui/$(''
    ''/bin/id -u)"''
    ''/bin/launchctl kickstart -k "$user_domain/org.nixos.skhd" >/dev/null 2>&1 || true''
    ''/bin/launchctl kickstart -k "$user_domain/org.nixos.sketchybar" >/dev/null 2>&1 || true''
    ''/bin/launchctl kickstart -k "$user_domain/org.nixos.macos-automation-bridge" >/dev/null 2>&1 || true''
  ];

  # JankyBorders was evaluated as Phase 3 and removed by operator decision
  # (2026-08-08): reactive solo-window hiding cannot be flash-free because
  # border windows are composited on the target Space before any signal fires,
  # and an always-on border was judged visually heavy. Guard the removal so a
  # future phase reintroduces it deliberately rather than by leftover config.
  bordersEnabled = homeConfig.config.services.jankyborders.enable;
  yabaiExtraConfig = cfg.services.yabai.extraConfig;
  strayBordersSignals = lib.hasInfix "borders-solo" yabaiExtraConfig;

  # SketchyBar runs the DATUM Lua tree on the resident SbarLua runtime.
  # Home Manager owns the recursive tree and generated Lua 5.5 bootstrap;
  # services.sketchybar.config stays empty so no inline configuration can
  # shadow that single deployment path.
  sketchybarEnabled = cfg.services.sketchybar.enable;
  sketchybarInlineConfig = cfg.services.sketchybar.config;
  sketchybarPackage = cfg.services.sketchybar.package;
  sketchybarTopmostPatchPath = ../darwin/window-management/sketchybar-topmost-in-place.patch;
  sketchybarTopmostPatch = builtins.readFile sketchybarTopmostPatchPath;
  sketchybarTopmostPatchIntact =
    builtins.elem (toString sketchybarTopmostPatchPath) (
      map toString (sketchybarPackage.patches or [ ])
    )
    && lib.all (needle: lib.hasInfix needle sketchybarTopmostPatch) [
      "bool geometry_changed = bar_manager->topmost != topmost;"
      "if (geometry_changed) {"
      "bar_manager_reset(bar_manager);"
      "bar_order_item_windows(bar_manager->bars[i]);"
      "return false;"
    ];
  barTreeDir = ../darwin/window-management/sketchybar-lua;
  barRootEntries = lib.sort builtins.lessThan (builtins.attrNames (builtins.readDir barTreeDir));
  barItemEntries = lib.sort builtins.lessThan (
    builtins.attrNames (builtins.readDir (barTreeDir + "/items"))
  );
  expectedBarRootEntries = [
    "colors.lua"
    "init.lua"
    "items"
    "settings.lua"
    "ui.lua"
  ];
  barItemFiles = [
    "spaces.lua"
    "weather.lua"
    "spotify.lua"
    "clock.lua"
    "battery.lua"
    "volume.lua"
    "network.lua"
    "menubar.lua"
  ];
  expectedBarItemEntries = lib.sort builtins.lessThan barItemFiles;
  barInit = builtins.readFile (barTreeDir + "/init.lua");
  barSettings = builtins.readFile (barTreeDir + "/settings.lua");
  barColors = builtins.readFile (barTreeDir + "/colors.lua");
  barUi = builtins.readFile (barTreeDir + "/ui.lua");
  barSpacesItem = builtins.readFile (barTreeDir + "/items/spaces.lua");
  barVolumeItem = builtins.readFile (barTreeDir + "/items/volume.lua");
  barBatteryItem = builtins.readFile (barTreeDir + "/items/battery.lua");
  barMenubarItem = builtins.readFile (barTreeDir + "/items/menubar.lua");
  # The exact syntactic needles below are specific enough to match source
  # directly. Avoid line-by-line transformations in evaluation: Linux CI
  # intentionally runs with a smaller evaluator stack than the target Mac.
  barSettingsCode = barSettings;
  barUiCode = barUi;
  barSpacesCode = barSpacesItem;
  barVolumeCode = barVolumeItem;
  barSpotifyItem = builtins.readFile (barTreeDir + "/items/spotify.lua");
  sketchybarDeployment = homeConfig.config.xdg.configFile."sketchybar";
  sketchybarBootstrap = homeConfig.config.xdg.configFile."sketchybar/sketchybarrc";
  sketchybarBootstrapText = builtins.unsafeDiscardStringContext sketchybarBootstrap.text;
  bootstrapNeedles = [
    ''export LUA_CPATH="/nix/store/''
    "-lua5.5-sbarLua-"
    ''/lib/lua/5.5/?.so;;"''
    "exec /nix/store/"
    "-lua-5.5."
    ''/bin/lua "$HOME/.config/sketchybar/init.lua"''
  ];
  homeDirectory = homeConfig.config.home.homeDirectory;
  bridgeSource = builtins.readFile ../pkgs/macos-automation-bridge/main.m;
  bridgeRecipe = builtins.readFile ../pkgs/macos-automation-bridge/default.nix;
  skhdRecipe = builtins.readFile ../pkgs/skhd/default.nix;
  bridgeAgent = cfg.launchd.user.agents.macos-automation-bridge;
  sketchybarAgent = cfg.launchd.user.agents.sketchybar;
  signedAppsActivation = homeConfig.config.home.activation.installSignedAutomationApps;
  signedAppsActivationText = builtins.unsafeDiscardStringContext signedAppsActivation.data;
  automationPolicy = builtins.fromJSON cfg.environment.etc."atyrode/automation-security.json".text;
  forbiddenAutomationConfigNeedles = [
    ".load "
    ".remap "
    ".taphold "
    "fn_layer"
    "SpoonInstall"
    "hs.loadSpoon"
    "~/.hammerspoon"
    "/opt/homebrew"
    "/usr/local"
  ];
  forbiddenAutomationConfig = lib.filter (
    needle: lib.any (text: lib.hasInfix needle text) ([ skhdConfig ] ++ barTreeTexts)
  ) forbiddenAutomationConfigNeedles;
  sketchybarRuntimePackageNames = map lib.getName cfg.services.sketchybar.extraPackages;
  installedFontPackageNames = map lib.getName cfg.fonts.packages;
  requestedFontFamilies = lib.all (needle: lib.hasInfix needle barSettingsCode) [
    ''measure = "JetBrainsMono Nerd Font",''
    ''word = "DM Sans",''
  ];
  barItemTexts = map (file: builtins.readFile (barTreeDir + "/items/${file}")) barItemFiles;
  barTreeTexts = [
    barInit
    barSettings
    barColors
    barUi
  ]
  ++ barItemTexts;
  barNonSpacesTexts = [
    barInit
    barSettings
    barUi
  ]
  ++ map (file: builtins.readFile (barTreeDir + "/items/${file}")) (
    lib.filter (file: file != "spaces.lua") barItemFiles
  );
  hasInTexts = texts: needle: lib.any (text: lib.hasInfix needle text) texts;
  expectedInitItemBlock = lib.concatStringsSep "\n" (
    map (file: ''require("items.${lib.removeSuffix ".lua" file}")'') barItemFiles
  );

  # DATUM is a measured 40pt full-width face, so yabai must reserve exactly
  # the bar height declared in settings.lua.
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
    lib.hasInfix ''sbar.add("event", "space_eager")'' barUiCode
    && lib.hasInfix ''driver:subscribe("space_eager", function(env)'' barSpacesCode
    && lib.hasInfix ''
      	generation = generation + 1
      	dirty = false
      	set_focus(target)'' barSpacesCode;

  # The source literals below are the complete width proof, not merely labels
  # for it. In the crowded regime each of ten groups is 16 + 4 + 20pt and
  # nine inter-group gaps are 12pt. The Q lane is 96 + 108pt, while the
  # pre-notch span is ((1710 - 186) / 2) - 20pt.
  # The lane's 96pt is a ceiling, not a cell: its app field is sized to its
  # ink under max_chars 9, and only the title fixes a width.
  spaceRailMaximum = 10 * (16 + 4 + 20) + 9 * 12;
  spaceQLaneMaximum = (20 + 68 + 8) + (84 + 24);
  spaceUsableSpan = (1710 - 186) / 2 - 20;
  spaceGeometryIntact =
    spaceRailMaximum == 508
    && spaceQLaneMaximum == 204
    && spaceUsableSpan == 742
    && spaceRailMaximum + spaceQLaneMaximum <= spaceUsableSpan
    && spaceUsableSpan - spaceRailMaximum - spaceQLaneMaximum >= 24
    && lib.all (needle: lib.hasInfix needle barSettingsCode) [
      "atom = 4,"
      "glyph = 8,"
      "field = 12,"
      "group = 24,"
      "padding_left = 20,"
      "notch_width = 186,"
      "icon_box = 20,"
      "numeral = 16,"
      "app_name = 60,"
      "window_title = 84,"
    ]
    && lib.all (needle: lib.hasInfix needle barSpacesCode) [
      "local POOL = 10"
      "local SLOTS = 3"
      ''icon = { string = "", width = settings.icon_box },''
      "width = settings.width.numeral,"
      "lead[sid]:set({ drawing = not first, icon = { width = gap } })"
      "width = settings.width.window_title,"
      ''width = "dynamic",''
      "max_chars = 9,"
      "padding_left = settings.gap.glyph,"
      "window_title:set({ drawing = true, label = { string = text } })"
      "active_app:set({ padding_right = settings.gap.glyph })"
      "padding_right = settings.notch_gap,"
      "if count >= 7 then"
      "return 1, false, settings.gap.field"
      "if count >= 5 then"
      "return 1, true, settings.gap.group"
      "return SLOTS, true, settings.gap.group"
      "padding_right = (shown > 0 or overflow > 0) and atom or 0,"
    ]
    # The app field must stay content-sized. A fixed cell there is ~40pt of
    # dead slack between a short name and the title it qualifies, which is the
    # gap the lane was reported for; only the title's fixed width is load
    # bearing, and it is what holds the notch gap still.
    && !(lib.hasInfix "settings.width.app_name" barSpacesCode);

  # Space groups must retain their app context and minimum datum-tick width.
  # Focus styling may animate only the numeral and its tick; nothing may zero
  # a group width or drive raw CLI animations.
  spacesCollapseRegression =
    lib.filter (line: builtins.match "^[ \t]*width[ \t]*=[ \t]*0[ \t]*,?[ \t]*(--.*)?$" line != null) (
      lib.splitString "\n" barSpacesItem
    )
    ++ lib.optional (lib.hasInfix "--animate" barSpacesItem) "--animate";
  spacesKeepAppIcons =
    lib.all (needle: lib.hasInfix needle barSpacesCode) [
      ''"app."''
      ''Orca = "com.stablyai.orca"''
      "app_image(name)"
      "drawing = false"
    ]
    && lib.hasInfix ''
      	active_app:set({ background = { image = { drawing = false } } })
      	active_app:set({ background = { image = { string = app_image(name) } } })'' barSpacesCode
    && !(lib.hasInfix "active_app:set({ background = { image = { drawing = true } } })" barSpacesCode);
  spacesKeepAdaptiveWidth = lib.all (needle: lib.hasInfix needle barSpacesCode) [
    "if count >= 7 then"
    "return 1, false, settings.gap.field"
    "if count >= 5 then"
    "return 1, true, settings.gap.group"
    "return SLOTS, true, settings.gap.group"
  ];

  # One hover owner per Space group. SketchyBar sizes an item's window to its
  # content and never to its padding, so hover subscriptions on the numeral,
  # the app slots and the overflow cell leave every interior atom gap unowned:
  # crossing one delivered an exit with no matching entry and dropped the
  # hover in the middle of a group. Each Space now carries exactly one
  # group-sized cell, pulled over the group by a negative padding of its own
  # width, and that cell is the sole subscriber to hover, click and scroll for
  # the whole rectangle.
  spacesSingleHoverOwner =
    lib.all (needle: lib.hasInfix needle barSpacesCode) [
      ''local ui = require("ui")''
      ''hit[sid] = sbar.add("item", "space." .. sid .. ".hit", {''
      ''icon = { string = "", width = settings.width.numeral },''
      "padding_left = -settings.width.numeral,"
      "local span = settings.width.numeral"
      "+ shown * (atom + settings.icon_box)"
      "+ (overflow > 0 and (atom + settings.width.numeral) or 0)"
      "hit[sid]:set({ drawing = true, icon = { width = span }, padding_left = -span })"
      "hit[sid]:set({ drawing = false })"
      "local function bind(sid)\n\tlocal item = hit[sid]"
      ''item:subscribe("mouse.clicked", function(env)''
      ''item:subscribe("mouse.scrolled", function(env)''
      "ui.hoverable(item, function()"
      "if hovered == sid then"
      "for sid = 1, POOL do\n\tbind(sid)\nend"
    ]
    # Exactly one registration, and nothing else in the rail listens for a
    # pointer: no child cell, and no per-item global exit beside
    # panels.driver's single release.
    && builtins.length (lib.splitString "ui.hoverable(" barSpacesCode) == 2
    && lib.all (needle: !(lib.hasInfix needle barSpacesCode)) [
      "hovered_item"
      "mouse.exited.global"
      ''subscribe("mouse.entered"''
      ''subscribe("mouse.exited"''
      "bind(numeral[sid], sid)"
      "bind(slot[sid][k], sid)"
      "bind(more[sid], sid)"
    ];

  # The Q lane commits app artwork, app name and window title as one state.
  # macOS names the frontmost app a query round trip before yabai can name the
  # window it focused, so an identity painted from that announcement is a
  # visible app-name-only blink on every switch. `commit` is the only painter,
  # it is reachable only from a completed window observation, and every
  # observation carries the focus epoch it was issued in, so an answer about
  # the app just left cannot repaint over the app just entered.
  spacesLaneAtomic =
    lib.all (needle: lib.hasInfix needle barSpacesCode) [
      "local focus_gen = 0"
      "local function paint_app(name)"
      "local function commit(name, text)"
      "if name ~= shown_app then"
      "local function absorb(windows, epoch)"
      "if epoch ~= focus_gen then"
      "local epoch = focus_gen"
      "absorb(windows, epoch)"
      "\tfront_app = name\n\tfocus_gen = focus_gen + 1\n\tresolve_lane()"
      "\tfocus_gen = focus_gen + 1\n\tsettle()"
    ]
    # The two-stage painters are gone: neither half of the lane may be written
    # on its own, and paint_app exists once and is called once, by commit.
    && !(lib.hasInfix "set_app(" barSpacesCode)
    && !(lib.hasInfix "set_title(" barSpacesCode)
    && builtins.length (lib.splitString "paint_app" barSpacesCode) == 3;
  hoverableContract =
    lib.all (needle: lib.hasInfix needle barUiCode) [
      "local releases = {}"
      "function M.hoverable(item, on_enter, on_leave)"
      "local entry = { leave = on_leave, lit = false }"
      "releases[#releases + 1] = entry"
      ''item:subscribe("mouse.entered", function(env)''
      ''item:subscribe("mouse.exited", function(env)''
      "entry.lit = true"
      "on_enter(env)"
      "on_leave(env)"
      "local function release_hovers()"
      "for _, entry in ipairs(releases) do"
      "if entry.lit then"
      "entry.lit = false"
      "entry.leave()"
      ''
        driver:subscribe("mouse.exited.global", function()
        	release_hovers()
        	M.close_all()
        end)''
      ''
        driver:subscribe({ "display_change", "space_eager", "system_woke" }, function()
        	M.close_all()
        end)''
    ]
    && !(lib.hasInfix ''item:subscribe("mouse.exited.global"'' barUiCode)
    && !(lib.hasInfix ''item:subscribe({ "mouse.exited", "mouse.exited.global" }'' barUiCode);

  # Broken/deprecated native event names must not survive even in comments:
  # stale prose is too easily copied back into a subscription.
  forbiddenBarEvents = lib.filter (event: hasInTexts barTreeTexts event) [
    "wifi_change"
    "media_change"
    "menubar_hover_on"
    "menubar_hover_off"
  ];

  lowerBarTreeTexts = map lib.toLower barTreeTexts;
  legacyRecessNeedles = map (digit: "colors.n${toString digit}") (lib.range 0 9) ++ [
    "colors.shadow_tray"
    "settings.tray_"
  ];

  # DATUM has no permanent item surfaces or deferred/opacity tricks. The
  # volume slider is a transient popup; the fixed top-row datum never grows.
  forbiddenBarMechanisms = lib.filter (needle: hasInTexts lowerBarTreeTexts needle) [
    ".tray"
    "sbar.delay"
    ".color.alpha"
  ];
  forbiddenLegacyRecessTokens = lib.filter (
    needle: hasInTexts lowerBarTreeTexts needle
  ) legacyRecessNeedles;

  # Pure white and emoji-presentation escapes violate the measured monochrome
  # type system. The accent token and literal are reserved to spaces.lua.
  forbiddenDesignTokens = lib.filter (needle: hasInTexts lowerBarTreeTexts needle) [
    "\\u{1f"
    "\\u{fe0f}"
    "0xffffffff"
  ];
  accentOutsideSpaces = lib.filter (needle: hasInTexts barNonSpacesTexts needle) [
    "colors.accent"
    "0xff70c0b1"
  ];
  requiredBarEventWiring = [
    ''active_app:subscribe("front_app_switched", function(env)''
    ''driver:subscribe({ "display_change", "system_woke" }, function()''
    ''sbar.add("event", "network_change")''
    ''network:subscribe("network_change", function(env)''
    ''sbar.add("event", "battery_change")''
    ''battery:subscribe("battery_change", function(env)''
    ''battery:subscribe({ "routine", "power_source_change", "system_woke", "forced" }, refresh)''
    ''volume:subscribe("volume_change", function(env)''
    ''sbar.add("event", "window_focus")''
    ''sbar.add("event", "windows_on_spaces")''
    ''driver:subscribe({ "windows_on_spaces", "window_focus", "forced" }, function()''
    ''sbar.add("event", "menubar_duck")''
    ''driver:subscribe("menubar_duck", function(env)''
    ''sbar.add("event", "spotify_change", "com.spotify.client.PlaybackStateChanged")''
  ];
  missingBarEventWiring = lib.filter (
    needle: !(hasInTexts barTreeTexts needle)
  ) requiredBarEventWiring;

  # A fixed-width mark slot includes its padding. Keep the measured cell
  # model live at every caller so a future glyph swap cannot silently crop
  # the mark or put numeric reserve slack back inside the pair.
  datumOpticsIntact = lib.all (needle: hasInTexts barTreeTexts needle) [
    "icon_scale = 0.625"
    "y_offset = -12"
    "percent = 31"
    "temp = 31"
    "clock_time = 47"
    "settings.glyph.weather + settings.gap.glyph"
    "settings.glyph.media + settings.gap.glyph"
    "settings.glyph.network + INSET"
    "settings.glyph.volume + settings.gap.glyph"
    "settings.glyph.battery + settings.gap.glyph"
    "settings.width.clock_date + settings.gap.glyph"
  ];
  statusGlyphsIntact =
    lib.all (needle: lib.hasInfix needle barVolumeItem) [
      ''\u{F057E}''
      ''\u{F0581}''
    ]
    && lib.all (needle: lib.hasInfix needle barBatteryItem) [
      ''\u{F0079}''
      ''\u{F0080}''
      ''\u{F007E}''
      ''\u{F007C}''
      ''\u{F007A}''
      ''\u{F0083}''
      ''\u{F0084}''
      ''\u{F0091}''
    ];
  mediaGlyphIntact =
    lib.hasInfix ''\u{F03E4}'' barSpotifyItem && !(lib.hasInfix ''\u{F0504}'' barSpotifyItem);
  volumeForbiddenInteraction = lib.filter (needle: lib.hasInfix needle barVolumeCode) [
    ''"volume.gap"''
    ''"volume.control"''
    ''"volume.level"''
    "set_expanded"
    ''sbar.add("bracket"''
    "hover_owner"
    "suppress_datum_click"
    "sbar.delay"
    "os.clock"
    "os.time"
    "timestamp"
    "width = expanded and"
    "width = hovered and"
    "drawing = expanded"
    "volume:set({ padding_"
    "volume:set({ width"
    "popup = { drawing"
    ".. env."
    "env.PERCENTAGE .."
    "env.INFO .."
    "env.SCROLL_DELTA .."
    "string.format(env."
    ''"volume.popup." ..''
  ];
  volumePanelIntact =
    lib.all (needle: lib.hasInfix needle barVolumeCode) [
      ''local ui = require("ui")''
      ''local POPUP_ID = "volume"''
      "local TRACK = 5 * settings.gap.group"
      "local SET_LEVEL = {}"
      "for pct = 0, 100 do"
      ''SET_LEVEL[pct] = "osascript -e 'set volume output volume "''
      ''local STEP_UP = "osascript -e 'set v to (output volume of (get volume settings)) + 5'"''
      ''local STEP_DOWN = "osascript -e 'set v to (output volume of (get volume settings)) - 5'"''
      ''local volume = sbar.add("item", "volume", {''
      "padding_right = settings.gap.group,"
      ''popup = ui.popup_config("right"),''
      ''local slider = sbar.add("slider", "volume.popup.level", TRACK, {''
      ''position = "popup.volume",''
      "width = TRACK,"
      "local function action_row(name, word)"
      ''local mute_row = action_row("volume.popup.mute", "Toggle Mute")''
      ''local settings_row = action_row("volume.popup.settings", "Sound Settings")''
      ''volume:subscribe("mouse.clicked", function(env)''
      ''if env.BUTTON == "right" then''
      "ui.close_popup(POPUP_ID)"
      "sbar.exec(SOUND_SETTINGS)"
      "if ui.toggle_popup(POPUP_ID, volume, paint) then"
      ''volume:subscribe("mouse.scrolled", function(env)''
      "sbar.exec(delta > 0 and STEP_UP or STEP_DOWN, apply)"
      ''slider:subscribe("mouse.clicked", function(env)''
      ''if env.BUTTON ~= "left" then''
      "local pct = tonumber(env.PERCENTAGE)"
      "sbar.exec(SET_LEVEL[clamp(pct)], apply)"
      ''mute_row:subscribe("mouse.clicked", function()''
      "sbar.exec(TOGGLE_MUTE, apply)"
      ''settings_row:subscribe("mouse.clicked", function()''
      "ui.hoverable(volume, function()"
      "for _, row in ipairs({ mute_row, settings_row }) do"
      ''mute_row:set({ icon = { string = muted and "Unmute" or "Mute" } })''
      "sbar.exec(READ, apply)"
    ]
    && builtins.length (lib.splitString ''position = "popup.volume"'' barVolumeCode) == 3
    && builtins.length (lib.splitString "env.PERCENTAGE" barVolumeCode) == 2
    && volumeForbiddenInteraction == [ ];

  # The resting window level is the notification contract: `topmost = "window"`
  # is kCGFloatingWindowLevel, below the status level a Notification Center
  # banner composites at, while the boolean form is that status level and made
  # DATUM outrank every banner. The status level is now a bounded lift for the
  # native-menu approach and dwell only, so both halves are pinned: the rest
  # level must be notification-safe, and the lift must have a way back down.
  # Throughout, mouse input stays read-only -- the two layers are separated by
  # level, never by touching the pointer or an event.
  menubarHandoffIntact =
    lib.all (needle: lib.hasInfix needle bridgeSource) [
      "static const NSTimeInterval LeadDwell = 0.70;"
      "static const NSTimeInterval ReturnHold = 0.14;"
      "static const NSTimeInterval SettleHold = 0.20;"
      "static const CGFloat LiftGuard = 4.0;"
      "scheduledTimerWithTimeInterval:LeadDwell"
      "scheduledTimerWithTimeInterval:ReturnHold"
      "scheduledTimerWithTimeInterval:SettleHold"
      "NSProcessInfo.processInfo.systemUptime"
      "NSEvent.mouseLocation"
      ''sendStateEvent:@"menubar_lift"''
      "com.apple.HIToolbox.beginMenuTrackingNotification"
      "com.apple.HIToolbox.endMenuTrackingNotification"
      "NSWorkspaceDidWakeNotification"
      "startMonitoringEventWithType:CWEventTypeLinkDidChange"
      "IOPSNotificationCreateRunLoopSource"
      "Association changes are the signal"
    ]
    && lib.all (needle: lib.hasInfix needle barMenubarItem) [
      ''sbar.add("event", "menubar_duck")''
      ''sbar.add("event", "menubar_lift")''
      ''driver:subscribe("menubar_lift", function(env)''
      "last_seq = { menubar_duck = 0, menubar_lift = 0 }"
      "tonumber(env.SEQ)"
      "settings.motion.duck.out"
      "settings.motion.duck.back"
      "down and -settings.bar_height or 0"
      ''topmost = up and "on" or "window"''
    ]
    && lib.hasInfix ''topmost = "window",'' barInit
    && !(lib.hasInfix "topmost = true" (barInit + barMenubarItem))
    && lib.all (needle: !(lib.hasInfix needle (bridgeSource + barMenubarItem))) [
      "DWELL_SECONDS = 0.35"
      "menubar_hover_on"
      "menubar_hover_off"
      "REVEAL_POLL"
      "REVEAL_TIMEOUT"
      "DATUM_HIDDEN_Y"
      "nativeReleased"
      "revealPending"
      "local suppress"
      "return suppress"
      ''{ "--query", "bar" }''
      "hs.json.decode"
      "CGEventCreateKeyboardEvent"
      "CGEventTapCreate"
      "addGlobalMonitorForEventsMatchingMask"
      "hs.mouse.absolutePosition({"
      "hs.eventtap.event.types.leftMouseDown"
      "hs.eventtap.event.types.leftMouseDragged"
      "hs.eventtap.event.types.rightMouseDragged"
      "hs.eventtap.event.types.otherMouseDragged"
      ":post()"
      "event:set"
      "reasons.approach = inMenubarBand"
    ];

  # DATUM's semantic palette is deliberately closed and shared by the bar and
  # popup face. Transparent is a null value rather than visual chrome.
  datumPaletteIntact = lib.all (token: lib.hasInfix token barColors) [
    "deck = 0xff1b1e24"
    "track = 0xff2e3340"
    "ink = 0xffe4e7ec"
    "ink_dim = 0xff8d94a3"
    "accent = 0xff70c0b1"
    "signal = 0xfff0c674"
    "transparent = 0x00000000"
  ];

  # yabai remains the source for current window and Space lifecycle events.
  # Match executable signal registrations, including their unique labels and
  # actions, rather than accepting an event name that appears only in prose.
  yabaiConfigLines = lib.splitString "\n" yabaiExtraConfig;
  requiredBarSignals = [
    {
      label = "bar-window-focus";
      event = "window_focused";
      trigger = "window_focus";
    }
    {
      label = "bar-windows-created";
      event = "window_created";
      trigger = "windows_on_spaces";
    }
    {
      label = "bar-windows-destroyed";
      event = "window_destroyed";
      trigger = "windows_on_spaces";
    }
    {
      label = "bar-windows-moved";
      event = "window_moved";
      trigger = "windows_on_spaces";
    }
    {
      label = "bar-space-changed";
      event = "space_changed";
      trigger = "windows_on_spaces";
    }
    {
      label = "bar-space-created";
      event = "space_created";
      trigger = "windows_on_spaces";
    }
    {
      label = "bar-space-destroyed";
      event = "space_destroyed";
      trigger = "windows_on_spaces";
    }
  ];
  malformedBarSignals = lib.filter (
    signal:
    let
      labelLines = lib.filter (line: lib.hasInfix "label=${signal.label} " line) yabaiConfigLines;
      exactRegistration =
        builtins.length labelLines == 1
        && lib.hasInfix "label=${signal.label} event=${signal.event} action='" (lib.head labelLines)
        && lib.hasInfix "-sketchybar-" (lib.head labelLines)
        && lib.hasSuffix "/bin/sketchybar --trigger ${signal.trigger}'" (lib.head labelLines);
    in
    !exactRegistration
  ) requiredBarSignals;

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
    && !(lib.hasPrefix "." line)
    && !(lib.hasPrefix " " line)
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
    "rctrl - h : yabai -m window --focus west"
    "rctrl + shift - l : yabai -m window --warp east"
    "rctrl - space : yabai -m window --toggle float"
    "rctrl - f : yabai -m window --toggle zoom-fullscreen"
    "rctrl - b : yabai -m space --balance"
    "rctrl - r ; resize"
    "resize < escape ; default"
  ]
  # Every vim direction has an arrow alias bound to the identical action, so a
  # hand arriving from Windows is never told a key "does nothing". Pinning both
  # halves keeps them from drifting apart into two different models.
  ++
    lib.concatMap
      (direction: [
        "rctrl - ${direction.arrow} : yabai -m window --focus ${direction.edge}"
        "rctrl - ${direction.vim} : yabai -m window --focus ${direction.edge}"
        "rctrl + shift - ${direction.arrow} : yabai -m window --warp ${direction.edge}"
        "rctrl + shift - ${direction.vim} : yabai -m window --warp ${direction.edge}"
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
    "rctrl - ${spaceKeycodes.${index}} : yabai -m space --focus ${index}"
    "rctrl + shift - ${spaceKeycodes.${index}} : yabai -m window --space ${index} && yabai -m space --focus ${index}"
  ]) (builtins.attrNames spaceKeycodes);
  missingBindings = lib.filter (binding: !(lib.hasInfix binding skhdConfig)) requiredBindings;

  # A dedicated launch agent owns exactly one native HID mapping: built-in
  # Caps Lock to right Control. skhd only consumes rctrl, so neither a virtual
  # keyboard nor a printable-key remap can return through its config.
  remapLines = lib.filter (line: lib.hasPrefix ".remap " line) configLines;
  capsLeaderService = cfg.launchd.user.agents.caps-lock-leader.serviceConfig;
  expectedCapsLeaderArguments = [
    "/usr/bin/hidutil"
    "property"
    "--matching"
    ''{"ProductID":0,"VendorID":0}''
    "--set"
    ''{"UserKeyMapping":[{"HIDKeyboardModifierMappingDst":30064771300,"HIDKeyboardModifierMappingSrc":30064771129}]}''
  ];
  legacyLeaderLines = lib.filter (line: lib.hasInfix "ctrl + alt + cmd" line) configLines;
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
      "${homeDirectory}/Applications/Managed Automation/skhd.app/Contents/MacOS/skhd"
      "-c"
      "/etc/skhdrc"
    ]
) "the Darwin workstation must launch the locally signed, stable skhd app bundle";
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
  !(builtins.hasAttr "jackielii/homebrew-tap" cfg.nix-homebrew.taps)
  && !(builtins.elem "jackielii/tap/skhd-zig" caskNames)
  && !(builtins.elem "hammerspoon" caskNames)
) "the retired third-party skhd tap and general-purpose Hammerspoon runtime must remain absent";
assert lib.assertMsg (!(builtins.elem "skhd" packageNames) && builtins.elem "yabai" packageNames)
  "the desktop capability exposes yabai while signed automation apps are installed by an audited activation";
assert lib.assertMsg (!(builtins.elem "karabiner-elements" caskNames))
  "Karabiner-Elements must stay out of the workstation: its virtual keyboard rewrites printable French ISO input";
assert lib.assertMsg (
  !(homeConfig.config.home.activation ? installKarabinerConfig)
) "Home Manager must not deploy or restart Karabiner; the native hidutil agent owns Caps Lock";
assert lib.assertMsg (remapLines == [ ]) (
  "skhd must not own HID remaps or request a keyboard grabber, but found: "
  + lib.concatStringsSep ", " remapLines
);
assert lib.assertMsg (
  capsLeaderService.ProgramArguments == expectedCapsLeaderArguments
  && capsLeaderService.RunAtLoad
  && capsLeaderService.ProcessType == "Background"
  && capsLeaderService.KeepAlive == null
) "the managed hidutil agent must map only built-in Caps Lock to right Control once at login";
assert lib.assertMsg (legacyLeaderLines == [ ]) (
  "all window-management bindings must consume the native right-Control leader; stale virtual-Hyper bindings remain: "
  + lib.concatStringsSep ", " legacyLeaderLines
);
assert lib.assertMsg (
  sketchybarDeployment.recursive
  && sketchybarDeployment.source == ../darwin/window-management/sketchybar-lua
) "Home Manager must recursively deploy the complete DATUM SketchyBar tree";
assert lib.assertMsg sketchybarTopmostPatchIntact
  "SketchyBar must re-level an already-topmost bar in place; resetting it exposes a solid bare face during native-menu handoff";
assert lib.assertMsg (barRootEntries == expectedBarRootEntries) (
  "the DATUM SketchyBar root module list drifted: expected "
  + lib.concatStringsSep ", " expectedBarRootEntries
  + " but found "
  + lib.concatStringsSep ", " barRootEntries
);
assert lib.assertMsg (barItemEntries == expectedBarItemEntries) (
  "the DATUM SketchyBar item module list drifted: expected "
  + lib.concatStringsSep ", " expectedBarItemEntries
  + " but found "
  + lib.concatStringsSep ", " barItemEntries
);
assert lib.assertMsg (lib.hasInfix expectedInitItemBlock barInit)
  "init.lua must load the complete DATUM item list in spaces/weather/spotify/clock/battery/volume/network/menubar order";
assert lib.assertMsg (
  sketchybarBootstrap.executable
  && lib.all (needle: lib.hasInfix needle sketchybarBootstrapText) bootstrapNeedles
) "Home Manager must generate an executable SbarLua bootstrap pinned to Lua 5.5";
assert lib.assertMsg
  (
    builtins.elem "installSignedAutomationApps" managedRestart.after
    && sketchybarAgent.serviceConfig.Label == "org.nixos.sketchybar"
    && bridgeAgent.serviceConfig.Label == "org.nixos.macos-automation-bridge"
    && lib.all (
      needle: lib.hasInfix (builtins.unsafeDiscardStringContext needle) managedRestartText
    ) managedRestartNeedles
  )
  "Home Manager must best-effort kickstart skhd, SketchyBar, and the narrow bridge only after signed apps are installed";
assert lib.assertMsg
  (
    lib.all (name: builtins.elem name sketchybarRuntimePackageNames) [
      "yabai"
      "lua"
      "curl"
    ]
    && lib.all (name: !(builtins.elem name sketchybarRuntimePackageNames)) [
      "gh"
      "git"
      "jq"
    ]
  )
  "SketchyBar runtime ownership must retain yabai, Lua 5.5, and curl without unused gh/git/jq widget dependencies";
assert lib.assertMsg
  (
    requestedFontFamilies
    && builtins.elem "nerd-fonts-jetbrains-mono" installedFontPackageNames
    && builtins.elem "google-fonts" installedFontPackageNames
    && lib.hasInfix ''(pkgs.google-fonts.override { fonts = [ "DM Sans" ]; })'' darwinWindowManagementSource
    && !(builtins.elem "dm-sans" installedFontPackageNames)
  )
  "DATUM settings and installed outputs must pair JetBrainsMono Nerd Font with Google Fonts' genuine DM Sans family";
assert lib.assertMsg (
  !(cfg.launchd.user.agents ? hammerspoon)
  && !(builtins.pathExists ../home/macos-window-management/hammerspoon-init.lua)
  &&
    bridgeAgent.serviceConfig.ProgramArguments == [
      "${homeDirectory}/Applications/Managed Automation/atyrode-automation-bridge.app/Contents/MacOS/atyrode-automation-bridge"
    ]
  && bridgeAgent.serviceConfig.KeepAlive
  && bridgeAgent.serviceConfig.RunAtLoad
  && bridgeAgent.serviceConfig.ProcessType == "Background"
  && bridgeAgent.managedBy == "darwin/window-management.nix"
) "Hammerspoon must remain removed and the narrow compiled bridge must own its former events";
assert lib.assertMsg
  (
    builtins.elem "linkGeneration" signedAppsActivation.after
    && lib.all (needle: lib.hasInfix needle signedAppsActivationText) [
      "security find-identity -v -p codesigning"
      ''/bin/chmod -R u+w "$staged"''
      "codesign --force --timestamp=none --options runtime"
      "codesign --verify --deep --strict"
      "Authority=$identity"
      "atyrode Local Automation"
      "skhd.app"
      "atyrode-automation-bridge.app"
    ]
  )
  "managed automation apps must be copied atomically and verified under the stable host-local signing identity";
assert lib.assertMsg
  (
    lib.hasInfix ''version = "0.2.0";'' skhdRecipe
    && lib.hasInfix "tag = \"v\${version}\";" skhdRecipe
    && lib.hasInfix ''hash = "sha256-Qi5srrpdhf3VcXaqZbijJD23Um0G7WgRzK0hR+mb7nU=";'' skhdRecipe
    && lib.hasInfix ''hash = "sha256-u/N1KkCeu4AgK4ZaR8PTgla1oDV5PsipiW48sImetW4=";'' skhdRecipe
    && lib.hasInfix ''.path = ".vendor/zbench",'' skhdRecipe
    && lib.hasInfix ''rm -f "$out/Applications/skhd.app/Contents/MacOS/skhd-grabber"'' skhdRecipe
    && lib.hasInfix ''test ! -e "$out/Applications/skhd.app/Contents/MacOS/skhd-grabber"'' skhdRecipe
    && lib.hasInfix ''rm -rf "$out/bin"'' skhdRecipe
    && lib.hasInfix "NSMicrophoneUsageDescription" skhdRecipe
    && !(lib.hasInfix "NSMicrophoneUsageDescription" bridgeSource)
    && lib.hasInfix "-fobjc-arc -Os -Wall -Wextra -Werror" bridgeRecipe
  )
  "skhd and the narrow bridge must remain source-pinned, locally built, and stripped of unused privileged surfaces";
assert lib.assertMsg (forbiddenAutomationConfig == [ ]) (
  "managed executable automation may not load plugins, Spoons, root grabbers, or unmanaged paths: "
  + lib.concatStringsSep ", " forbiddenAutomationConfig
);
assert lib.assertMsg
  (
    automationPolicy.schemaVersion == 1
    && automationPolicy.signingIdentity == "atyrode Local Automation"
    && automationPolicy.expectedSIPEnabled
    && !automationPolicy.expectedScriptingAdditionEnabled
    && automationPolicy.allowedTcpListeners == [ ]
    && automationPolicy.tccReview.maxAgeDays == 90
    && builtins.length automationPolicy.managedApplications == 2
    && builtins.elem "Hammerspoon" automationPolicy.forbiddenProcesses
    && builtins.elem "skhd-grabber" automationPolicy.forbiddenProcesses
  )
  "the machine-readable automation policy must pin least privilege, identity checks, and quarterly TCC review";
assert lib.assertMsg menubarHandoffIntact
  "the native/custom menu-bar handoff must keep its measured lead/hold/settle timers, ordered per-event delivery, bar-only y-offset strokes, a notification-safe resting window level, and a status level that is only ever a bounded lift";
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
  "space_eager must be registered and subscribed, then invalidate in-flight queries immediately before painting its target";
assert lib.assertMsg spaceGeometryIntact
  "Space geometry must derive 508pt + 204pt <= 742pt with at least a 24pt residual gap";
assert lib.assertMsg (spacesCollapseRegression == [ ]) (
  "Space groups must keep their app context and datum ticks live; offending"
  + " collapse/CLI animation constructs in spaces.lua: "
  + lib.concatStringsSep ", " spacesCollapseRegression
);
assert lib.assertMsg spacesKeepAppIcons
  "spaces.lua must disable the stale app image before assigning its replacement without explicitly re-enabling it";
assert lib.assertMsg spacesKeepAdaptiveWidth
  "spaces.lua must retain the exact 7-Space compact-gap and 5-Space one-icon adaptive regime";
assert lib.assertMsg spacesSingleHoverOwner
  "each Space must own hover, click and scroll through exactly one group-sized cell laid over its whole group; no child cell and no per-item global exit may compete for hover";
assert lib.assertMsg spacesLaneAtomic
  "the Q lane must commit app artwork, app name and window title as one epoch-guarded state: no synchronous app-only paint path may survive and no spent-epoch query answer may reach the lane";
assert lib.assertMsg hoverableContract
  "ui.hoverable hosts must subscribe only to enter/local exit and register their release for panels.driver's sole global-exit callback";
assert lib.assertMsg (missingBarEventWiring == [ ]) (
  "the Lua tree lost required event registrations or subscriptions: "
  + lib.concatStringsSep ", " missingBarEventWiring
);
assert lib.assertMsg (forbiddenBarEvents == [ ]) (
  "the Lua tree subscribes to events broken or deprecated on this macOS: "
  + lib.concatStringsSep ", " forbiddenBarEvents
);
assert lib.assertMsg datumOpticsIntact
  "DATUM mark slots must preserve the measured inside-padding geometry and fixed numeric reserves";
assert lib.assertMsg mediaGlyphIntact
  "Spotify must use the verified md-pause codepoint, never md-temperature-celsius";
assert lib.assertMsg statusGlyphsIntact
  "volume and battery must retain the width-stable Material Design glyph sets sized by the audited cells";
assert lib.assertMsg volumePanelIntact
  "volume must remain a fixed bar datum and expose an explicit arbitrated level/mute/settings popup with static rows, color-only hover, clamped finite slider commands, and stable click/scroll actions";
assert lib.assertMsg (forbiddenBarMechanisms == [ ]) (
  "the Lua tree reintroduced static tray names, deferred callbacks, or per-item alpha mutation: "
  + lib.concatStringsSep ", " forbiddenBarMechanisms
);
assert lib.assertMsg (forbiddenLegacyRecessTokens == [ ]) (
  "the Lua tree reintroduced legacy nXX/tray recess tokens: "
  + lib.concatStringsSep ", " forbiddenLegacyRecessTokens
);
assert lib.assertMsg datumPaletteIntact
  "colors.lua must define DATUM deck/track/ink/ink_dim/accent/signal and transparent at their audited values";
assert lib.assertMsg (forbiddenDesignTokens == [ ]) (
  "the Lua tree violates the DATUM design pins (no colour emoji or pure white): "
  + lib.concatStringsSep ", " forbiddenDesignTokens
);
assert lib.assertMsg (accentOutsideSpaces == [ ]) (
  "DATUM accent is exclusive to the focused Space tick; uses outside spaces.lua: "
  + lib.concatStringsSep ", " accentOutsideSpaces
);
assert lib.assertMsg (malformedBarSignals == [ ]) (
  "yabai signal registrations are missing, duplicated, or miswired: "
  + lib.concatStringsSep ", " (map (signal: signal.label) malformedBarSignals)
);
pkgs.runCommand "check-window-management-${pkgs.system}" { } ''
  mkdir "$out"
''
