{ pkgs }:

pkgs.runCommand "check-preview-owner-pin"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    updater = ../../ci/update-preview-owner.py;
    test = ./preview-owner-pin-test.py;
  }
  ''
    python3 "$test" "$updater"
    mkdir "$out"
  ''
