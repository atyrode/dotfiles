{ pkgs }:
pkgs.runCommand "check-myparcelle-ci-clever-guard-budget"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    # The guard prices Paris days: zoneinfo needs a database inside the sandbox.
    PYTHONTZPATH = "${pkgs.tzdata}/share/zoneinfo";
  }
  ''
    python3 ${./myparcelle-ci-clever-guard-budget.py} ${../../modules/nixos/myparcelle-ci-clever-guard.py}
    mkdir "$out"
  ''
