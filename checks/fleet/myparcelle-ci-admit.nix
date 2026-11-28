{ pkgs }:
pkgs.runCommand "check-myparcelle-ci-admit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./myparcelle-ci-admit.py} ${../../modules/nixos/myparcelle-ci-admit.py}
  mkdir "$out"
''
