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

  # The SketchyBar configuration is the faithful FelixKratz e6288b3 port
  # committed under darwin/window-management/sketchybar. SketchyBar never
  # rewrites its config, so store symlinks are safe here (unlike Karabiner).
  # icon_map.sh comes from the sketchybar-app-font package: the same project
  # Felix's snapshot was taken from, maintained as a superset of it, so
  # current applications resolve instead of falling back to ":default:".
  xdg.configFile = lib.mkIf pkgs.stdenv.isDarwin {
    "sketchybar" = {
      source = ../darwin/window-management/sketchybar;
      recursive = true;
    };
    "sketchybar/plugins/icon_map.sh".source = "${pkgs.sketchybar-app-font}/bin/icon_map.sh";
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
