# The scripts a Mac runs with the Bash a Mac has.
#
# macOS ships Bash 3.2 and nothing in this repository can change that for a
# script that runs before Nix exists, or for one GitHub Actions invokes through
# `/bin/bash`. Every Bash 4 construct below is silently absent there: the
# script does not fail to parse, it fails at the line that uses it, which on a
# publish step means a green-looking pipeline that quietly stopped publishing.
# That is how this check came to exist.
#
# Scripts the Nix-built CLI runs are deliberately not scanned: they carry a
# shebang into a Bash 5 the closure provides, and holding them to 3.2 would
# cost real expressiveness for a constraint they do not have.
{ pkgs }:

pkgs.runCommand "check-macos-bash"
  {
    scripts = [
      ../../bootstrap/install.sh
      ../../get.sh
      ../../ci/publish-store.sh
      ../../ci/update-pins.sh
      ../../ci/docs-drift-guard.sh
      ../../ci/classify-ci-paths.sh
    ];
  }
  ''
    fail=0
    for script in $scripts; do
      # A comment may name the construct it avoids, which is the one place the
      # word belongs; only code is scanned.
      if sed 's/#.*//' "$script" |
        grep -Eq 'mapfile|readarray|declare -A|local -n|\[\[ -v |\$\{[^}]+,,\}|\$\{[^}]+\^\^\}'; then
        echo "$script uses a Bash 4 construct that macOS does not have" >&2
        fail=1
      fi
    done
    test "$fail" -eq 0
    mkdir "$out"
  ''
