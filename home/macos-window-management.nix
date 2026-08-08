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

  # JankyBorders only renders focus; it owns no windows and no hotkeys. Colors
  # come from the palette the repository already owns: the active accent is
  # Rio's vi-cursor teal, the inactive frame is the muted gray one step above
  # Rio's #282C34 background. Width 5 sits inside the 8px yabai gaps without
  # touching the neighbouring window.
  services.jankyborders = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    settings = {
      style = "round";
      width = 5.0;
      hidpi = "on";
      active_color = "0xff70c0b1";
      inactive_color = "0xff3e4451";
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
