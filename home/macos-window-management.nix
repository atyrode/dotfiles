{
  lib,
  pkgs,
  ...
}:

{
  home.packages = lib.optionals pkgs.stdenv.isDarwin [
    pkgs.yabai
  ];

  # Home Manager recursively owns the complete DATUM Lua tree. SketchyBar
  # never rewrites its configuration, so store symlinks are safe. The generated
  # executable bootstrap pins both the SbarLua C
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

  # The resident desktop consumers are owned by nix-darwin launch agents,
  # while Home Manager owns the Lua links they read. Relaunch them only after
  # the new generation is linked so configuration changes become live without
  # logout. A label may not be bootstrapped until its app has completed first
  # launch; kickstart is therefore deliberately best-effort.
  home.activation.restartManagedDesktopConsumers = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [[ -v DRY_RUN ]]; then
        echo "Would relaunch managed skhd, SketchyBar, and Hammerspoon agents"
      else
        user_domain="gui/$(${pkgs.coreutils}/bin/id -u)"
        /bin/launchctl kickstart -k "$user_domain/org.nixos.skhd" >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k "$user_domain/org.nixos.sketchybar" >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k "$user_domain/org.nixos.hammerspoon" >/dev/null 2>&1 || true
      fi
    ''
  );

}
