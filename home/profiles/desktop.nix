{
  # Darwin desktop packages currently live in home/packages.nix and
  # darwin/default.nix. Issue #18 will finish package ownership; this module
  # already makes the Linux desktop selection explicit and composable.
  imports = [ ../linux-desktop.nix ];
}
