{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
in
mkScenario "lint" ''
  bash -n "$bootstrap"
  shellcheck -x "$bootstrap"
  if grep -Eq 'mapfile|declare -A|local -n|\[\[ -v |\$\{[^}]+,,\}|flock|stat -c' \
    "$bootstrap"; then
    echo 'bootstrap uses a construct unavailable before Nix or on Bash 3.2' >&2
    exit 1
  fi
''
