{ lib, pkgs }:
pkgs.runCommand "check-omp-interactive"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.git
      pkgs.bash
    ];
  }
  ''
    cp ${../../ci/check-omp-interactive.py} check-omp-interactive.py
    cp ${../../ci/check-agent-context.py} check-agent-context.py
    python3 check-omp-interactive.py \
      --raw ${lib.getExe pkgs.omp} \
      --configured ${pkgs.omp-configured}
    touch "$out"
  ''
