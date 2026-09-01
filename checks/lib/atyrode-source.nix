# The CLI's text, as one file.
#
# `atyrode` is an entry point plus modules under pkgs/atyrode/lib. Several
# checks assert on its source rather than its behaviour -- that a diagnostic
# never mutates, that an offer runs the command it names -- and those
# assertions are about the CLI, not about which file a function currently
# lives in. Concatenating here means moving a function between modules cannot
# quietly empty a scan that was still reporting success.
{ pkgs }:
pkgs.runCommand "atyrode-source.sh" { } ''
  cat ${../../pkgs/atyrode/atyrode} ${../../pkgs/atyrode/lib}/*.sh > "$out"
  # A scan over an empty file passes every negative assertion ever written
  # against it, so the size is the assertion that keeps the others honest.
  test -s "$out"
''
