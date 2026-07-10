{
  hostConfigs,
  lib,
  pkgs,
}:

let
  matrix = ../inventory/packages.json;
  serverPackages = map lib.getName hostConfigs."alex@ubuntu-4gb-nbg1-1".config.home.packages;
  forbiddenServerPackages = [
    "android-tools"
    "arduino-ide"
    "bun"
    "deno"
    "ffmpeg"
    "gcc"
    "godot"
    "go"
    "nodejs"
    "parsec-bin"
    "python"
    "rustc"
    "scrcpy"
    "steam"
    "uv"
    "vscode"
  ];
  leakedServerPackages = lib.intersectLists serverPackages forbiddenServerPackages;
in
assert lib.assertMsg (leakedServerPackages == [ ]) "server capability leaked workstation packages";
pkgs.runCommand "check-package-ownership"
  {
    nativeBuildInputs = [ pkgs.jq ];
  }
  ''
    jq -e '
      length > 0
      and all(.[];
        (.owner | type == "string" and length > 0)
        and (.deliveryLayer | type == "string" and length > 0)
        and (.selectedBy | type == "array")
        and (.consumer | type == "string" and length > 0)
        and (.versionOwner | type == "string" and length > 0)
        and (.mutableState | type == "string" and length > 0)
        and (.closureClass | type == "string" and length > 0)
        and (.packages | type == "array" and length > 0))
      and ([.[].packages[]] | length == (unique | length))
    ' ${matrix} >/dev/null
    mkdir "$out"
  ''
