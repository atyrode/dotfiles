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

  # The SketchyBar configuration is Lua on the SbarLua runtime, deployed as
  # the darwin/window-management/sketchybar-lua tree. SketchyBar never
  # rewrites its config, so store symlinks are safe here (unlike Karabiner).
  # The sketchybarrc bootstrap is generated because it must name store paths:
  # the SbarLua C module (LUA_CPATH), the sketchybar-app-font ligature table
  # (LUA_PATH), and the Lua 5.5 interpreter the module is compiled against.
  xdg.configFile = lib.mkIf pkgs.stdenv.isDarwin {
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
        export LUA_PATH="$HOME/.config/sketchybar/?.lua;$HOME/.config/sketchybar/?/init.lua;${pkgs.sketchybar-app-font}/lib/sketchybar-app-font/?.lua;;"
        exec ${pkgs.lua5_5}/bin/lua "$HOME/.config/sketchybar/init.lua"
      '';
    };
  };

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
