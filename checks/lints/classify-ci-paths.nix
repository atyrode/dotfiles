{ pkgs }:

pkgs.runCommand "check-classify-ci-paths"
  {
    nativeBuildInputs = [ pkgs.bash ];
    classifier = ../../ci/classify-ci-paths.sh;
    test = ../../ci/classify-ci-paths-test.sh;
  }
  ''
    CLASSIFIER="$classifier" bash "$test"
    mkdir "$out"
  ''
