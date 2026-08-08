{ lib, pkgs, ... }:

let
  yabai = lib.getExe pkgs.yabai;
in
{
  services.yabai = {
    enable = true;
    package = pkgs.yabai;

    # Deliberate operator decision (2026-08-08), reversing the Phase 1 default.
    # The scripting addition needs SIP partially disabled (Recovery:
    # `csrutil enable --without fs --without debug --without nvram`, then
    # `sudo nvram boot-args=-arm64e_preview_abi`, two reboots). nix-darwin
    # wires a hash-pinned sudoers entry -- only this exact yabai binary may run
    # `--load-sa` as root -- and a root daemon that loads it at boot.
    # Unlocks window animations, Space create/destroy, opacity, sticky.
    # Until the SIP change is performed the load daemon fails and yabai runs
    # exactly as before; every non-SA feature is unaffected.
    enableScriptingAddition = true;

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

      # Animates yabai-initiated frame changes (warp, balance, zoom, moves).
      # Requires the scripting addition and a Screen Recording grant for yabai;
      # macOS prompts on first animated change. NOTE: the grant is keyed to the
      # Nix store path, so a yabai version bump requires re-approval. Does NOT
      # animate neighbours during a live mouse drag -- that capability does not
      # exist in yabai; frames apply when the drag ends.
      window_animation_duration = 0.25;
    };

    # Start with utility windows whose floating behavior is predictable. Add
    # application routing only after the manual Space workflow has settled.
    extraConfig = ''
      ${yabai} -m rule --add label=system-settings app='^System Settings$' manage=off
      ${yabai} -m rule --add label=calculator app='^Calculator$' manage=off
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
