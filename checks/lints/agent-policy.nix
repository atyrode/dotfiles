{ lib, pkgs }:

let
  # Include the three deployed shapes and their sole authored source. The
  # helpers and transport fixtures never need a network or a live checkout.
  src = lib.fileset.toSource {
    root = ../../.;
    fileset = ../../.;
  };
in
pkgs.runCommand "check-agent-policy"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.gitMinimal
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    python3 ${./agent-policy-test.py} ${../../ci/agent-policy.py}
    python3 ${./agent-policy-sync-test.py} ${../../ci/agent-policy-sync.py} ${../../ci/agent-policy.py}
    python3 ${../../ci/agent-policy.py} check \
      --source ${src}/modules/home/agents/engineering.md \
      --root ${src} --layout dotfiles
    mkdir "$out"
  ''
