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

      # The bar is a transparent full-width strip at the top edge (neutonfoo
      # language: chips float on the wallpaper, no slab); the native menu bar
      # auto-hides (reachable by mousing to the top). Reserve exactly the bar
      # height from settings.lua; the check derives this sum from that file.
      external_bar = "all:38:0";
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
  # The configuration is Lua on SbarLua (resident process, direct mach IPC --
  # no fork-per-event), visual language from neutonfoo/dotfiles (transparent
  # bar, floating chips, notch-aware layout) on the Rio palette, with plugin
  # logic descended from the validated FelixKratz e6288b3 port. Deployed to
  # ~/.config/sketchybar by Home Manager; `config` stays unset so the daemon
  # boots the tree's own sketchybarrc, which execs the Lua runtime.
  services.sketchybar = {
    enable = true;
    extraPackages = [
      pkgs.yabai
      pkgs.jq
      pkgs.gh
      pkgs.lua5_5
      pkgs.curl
      pkgs.git
    ];
  };

  # The Karabiner virtual keyboard (vendor 1241, product 41119) must be
  # registered ISO (41) in macOS's per-device keyboard-type store. The
  # Keyboard Setup Assistant once recorded it as ANSI (40), which swaps the
  # `@` and `<` keys on the French ISO layout -- every keystroke flows through
  # the virtual device, so its type wins. Root-owned plist, so enforce it at
  # activation; takes effect at next login.
  system.activationScripts.extraActivation.text = ''
    /usr/bin/defaults write /Library/Preferences/com.apple.keyboardtype keyboardtype \
      -dict-add "41119-1241-0" -int 41
  '';

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
  # JetBrainsMono Nerd Font carries every widget glyph as a codepoint
  # (neutonfoo's one-family approach); the app font renders only the per-app
  # ligatures in Space and front-app chips.
  fonts.packages = [
    pkgs.sketchybar-app-font
    pkgs.nerd-fonts.jetbrains-mono
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
