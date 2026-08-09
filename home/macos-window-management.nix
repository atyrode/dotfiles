{
  config,
  lib,
  pkgs,
  ...
}:

let
  karabinerConfig = ./macos-window-management/karabiner.json;
  karabinerDirectory = "${config.home.homeDirectory}/.config/karabiner";
  karabinerPath = "${karabinerDirectory}/karabiner.json";
in
{
  home.packages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.yabai
  ];

  # Home Manager recursively owns the complete DATUM Lua tree. SketchyBar
  # never rewrites its configuration, so store symlinks are safe here (unlike
  # Karabiner). The generated executable bootstrap pins both the SbarLua C
  # module ABI and its Lua 5.5 interpreter; the tree remains the sole runtime
  # entry point.
  xdg.configFile = lib.optionalAttrs pkgs.stdenv.isDarwin {
    "sketchybar" = {
      source = ../darwin/window-management/sketchybar-lua;
      recursive = true;
    };
    "sketchybar/sketchybarrc" = {
      executable = true;
      text = ''
        #!/bin/bash
        # Generated bootstrap: exec the Lua runtime against this tree.
        export LUA_CPATH="${pkgs.sbarlua}/lib/lua/5.5/?.so;;"
        export LUA_PATH="$HOME/.config/sketchybar/?.lua;$HOME/.config/sketchybar/?/init.lua;;"
        exec ${pkgs.lua5_5}/bin/lua "$HOME/.config/sketchybar/init.lua"
      '';
    };
  };

  # Hammerspoon owns the native top-edge, Wi-Fi, and battery bridges that emit
  # SketchyBar events. Its managed config is paired with the nix-darwin agent;
  # Hammerspoon never rewrites init.lua, so a store symlink is safe.
  home.file = lib.optionalAttrs pkgs.stdenv.isDarwin {
    ".hammerspoon/init.lua" = {
      source = ./macos-window-management/hammerspoon-init.lua;
    };
  };

  # Both resident Lua consumers are owned by nix-darwin launch agents, while
  # Home Manager owns their linked configuration. Relaunch them only after the
  # new generation is linked so Lua-only changes become live without logout.
  # A label may not be bootstrapped until its app has completed first launch;
  # kickstart is therefore deliberately best-effort.
  home.activation.restartManagedLuaConsumers = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [[ -v DRY_RUN ]]; then
        echo "Would relaunch managed SketchyBar and Hammerspoon agents"
      else
        user_domain="gui/$(${pkgs.coreutils}/bin/id -u)"
        /bin/launchctl kickstart -k "$user_domain/org.nixos.sketchybar" >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k "$user_domain/org.nixos.hammerspoon" >/dev/null 2>&1 || true
      fi
    ''
  );

  # Karabiner owns input transformation only: Caps Lock held becomes the
  # control+option+command leader that skhd already binds; tapping it does
  # nothing by design. skhd owns hotkey dispatch, yabai owns windows.
  #
  # The live file is a regular writable 0600 file rather than a store symlink,
  # for two upstream reasons. Karabiner reloads by watching the enclosing
  # directory with FSEvents and documents that a symlinked karabiner.json
  # defeats that watch. Its writer also renames a temporary file over the
  # target, and rename(2) acts on the link rather than the store path, so any
  # Settings toggle or profile switch would silently swap the symlink for a
  # regular file and desynchronise the next activation. Writing a real file and
  # replacing it atomically keeps the reload trigger intact and makes a
  # Karabiner-side write a recoverable drift instead of a broken generation.
  home.activation.installKarabinerConfig = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        if [[ -v DRY_RUN ]]; then
          echo "Would install Karabiner configuration at ${karabinerPath}"
        else
          ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg karabinerDirectory}
          temporary=${lib.escapeShellArg "${karabinerPath}.tmp"}.$$
          ${pkgs.coreutils}/bin/install -m 0600 ${karabinerConfig} "$temporary"
          ${pkgs.coreutils}/bin/mv -f "$temporary" ${lib.escapeShellArg karabinerPath}
          # The directory watch is the documented reload trigger, but it only
          # exists once Karabiner has run. Kickstart is best-effort so a machine
          # without the driver approved yet still activates cleanly.
          /bin/launchctl kickstart -k \
            "gui/$(${pkgs.coreutils}/bin/id -u)/org.pqrs.service.agent.karabiner_console_user_server" \
            >/dev/null 2>&1 || true
        fi
      ''
  );
}
