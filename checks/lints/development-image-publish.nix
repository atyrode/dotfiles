{ pkgs }:

pkgs.runCommand "check-development-image-publish"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    publisher = ../../ci/publish-development-image.py;
    test = ./development-image-publish-test.py;
  }
  ''
    python3 "$test" "$publisher"
    mkdir "$out"
  ''
