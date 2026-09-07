{ lib, pkgs }:

let
  # Unrelated documentation must not change this derivation: the docs-only
  # drift guard permits only its declared documentation lints to vary.
  src = lib.fileset.toSource {
    root = ../../.;
    fileset = lib.fileset.unions [
      ../../AGENTS.md
      ../../modules/home/agents/engineering.md
      ../../modules/home/agents/templates/repo-AGENTS.md
    ];
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
