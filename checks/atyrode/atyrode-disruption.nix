{ pkgs, atyrode }:
pkgs.runCommand "check-atyrode-disruption"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    python3 ${./disruption-test.py} ${atyrode}/libexec/atyrode-disruption
    touch "$out"
  ''
