{
  homeDirectory,
  lib,
  pkgs,
  ...
}:

let
  yabai = lib.getExe pkgs.yabai;
  sketchybarPackage = pkgs.sketchybar.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./window-management/sketchybar-topmost-in-place.patch ];
  });
  sketchybarBin = "${sketchybarPackage}/bin/sketchybar";
  builtInKeyboardMatch = builtins.toJSON {
    VendorID = 0;
    ProductID = 0;
  };
  capsLockLeaderMapping = builtins.toJSON {
    UserKeyMapping = [
      {
        HIDKeyboardModifierMappingSrc = 30064771129;
        HIDKeyboardModifierMappingDst = 30064771300;
      }
    ];
  };
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
    package = sketchybarPackage;
    extraPackages = [
      pkgs.yabai
      pkgs.lua5_5
      pkgs.curl
    ];
  };

  # Preserve macOS's native keyboard layout and change exactly one HID usage:
  # Caps Lock (0x700000039) becomes right Control (0x7000000e4) on the built-in
  # keyboard. `hidutil` is the macOS-native mapping layer; unlike a keyboard
  # grabber, it creates no virtual device and never rewrites printable keys.
  launchd.user.agents.caps-lock-leader = {
    serviceConfig = {
      ProgramArguments = [
        "/usr/bin/hidutil"
        "property"
        "--matching"
        builtInKeyboardMatch
        "--set"
        capsLockLeaderMapping
      ];
      ProcessType = "Background";
      RunAtLoad = true;
    };

    managedBy = "darwin/window-management.nix";
  };

  # A host-local certificate gives skhd a stable, auditable TCC identity. Nix
  # pins and builds the source; Home Manager verifies, copies, and signs the app
  # at this stable path before nix-darwin restarts the agent.
  environment.etc."skhdrc".text = builtins.readFile ./window-management/skhdrc;

  launchd.user.agents.skhd = {
    serviceConfig = {
      ProgramArguments = [
        "${homeDirectory}/Applications/Managed Automation/skhd.app/Contents/MacOS/skhd"
        "-c"
        "/etc/skhdrc"
      ];
      EnvironmentVariables.PATH = "${pkgs.yabai}/bin:${sketchybarPackage}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      KeepAlive = true;
      ProcessType = "Interactive";
      RunAtLoad = true;
    };

    managedBy = "darwin/window-management.nix";
  };

  # A narrow compiled helper replaces the general-purpose Hammerspoon runtime.
  # It polls only the public mouse position, observes screen/menu/wake/Wi-Fi/
  # battery state, and launches SketchyBar with fixed argv; it cannot load Lua,
  # synthesize input, read SSIDs, or open a network listener.
  launchd.user.agents.macos-automation-bridge = {
    serviceConfig = {
      ProgramArguments = [
        "${homeDirectory}/Applications/Managed Automation/atyrode-automation-bridge.app/Contents/MacOS/atyrode-automation-bridge"
      ];
      KeepAlive = true;
      ProcessType = "Background";
      RunAtLoad = true;
    };

    managedBy = "darwin/window-management.nix";
  };

  # Machine-readable least-privilege contract consumed by `atyrode doctor
  # system` and the periodic `atyrode tcc-review` acknowledgement workflow.
  environment.etc."atyrode/automation-security.json".text = builtins.toJSON {
    schemaVersion = 1;
    signingIdentity = "atyrode Local Automation";
    expectedSIPEnabled = true;
    expectedScriptingAdditionEnabled = false;
    allowedTcpListeners = [ ];
    forbiddenProcesses = [
      "skhd-grabber"
      "karabiner_grabber"
      "Karabiner-Core-Service"
      "Hammerspoon"
    ];
    managedApplications = [
      {
        name = "skhd";
        path = "${homeDirectory}/Applications/Managed Automation/skhd.app";
        bundleIdentifier = "com.jackielii.skhd";
        version = "skhd.zig v0.2.0-7e95d99 (fast)";
      }
      {
        name = "atyrode-automation-bridge";
        path = "${homeDirectory}/Applications/Managed Automation/atyrode-automation-bridge.app";
        bundleIdentifier = "dev.tyrode.automation-bridge";
        version = "atyrode-automation-bridge 1.0.0";
      }
    ];
    immutableConfigurationPaths = [
      "/etc/skhdrc"
      "${homeDirectory}/.config/sketchybar"
    ];
    tccReview = {
      maxAgeDays = 90;
      grants = {
        yabai = {
          required = [
            "Accessibility"
            "Background Items"
          ];
          prohibited = [
            "Screen Recording"
            "Input Monitoring"
            "Full Disk Access"
          ];
        };
        skhd = {
          required = [
            "Accessibility"
            "Background Items"
          ];
          prohibited = [
            "Input Monitoring"
            "Microphone"
            "Camera"
            "Screen Recording"
            "Full Disk Access"
          ];
        };
        atyrode-automation-bridge = {
          required = [ "Background Items" ];
          prohibited = [
            "Accessibility"
            "Input Monitoring"
            "Location Services"
            "Microphone"
            "Camera"
            "Screen Recording"
            "Full Disk Access"
          ];
        };
        SketchyBar = {
          required = [ "Background Items" ];
          prohibited = [
            "Accessibility"
            "Input Monitoring"
            "Microphone"
            "Camera"
            "Screen Recording"
            "Full Disk Access"
          ];
        };
      };
    };
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
