{ pkgs }:

pkgs.runCommand "check-omp-model-facts"
  {
    nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.ruamel-yaml ])) ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    python3 ${../../ci/check-model-facts.py} \
      ${../../pkgs/omp-configured/config/refresh-model-facts.py} \
      ${../../.github/workflows/model-facts-freshness.yml}
    mkdir "$out"
  ''
