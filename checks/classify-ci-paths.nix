{ pkgs }:

pkgs.runCommand "check-classify-ci-paths"
  {
    nativeBuildInputs = [ pkgs.bash ];
    classifier = ../scripts/classify-ci-paths.sh;
    test = ../scripts/classify-ci-paths-test.sh;
  }
  ''
    CLASSIFIER="$classifier" bash "$test"
    mkdir "$out"
  ''
