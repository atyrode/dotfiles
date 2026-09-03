# Software the operator likes but needs a few times a year. It is reviewed
# data and nothing more: no machine declares any of it, no profile carries it,
# and `atyrode run <name>` launches an entry straight out of nixpkgs. The list
# exists because the cost of an occasional tool is not disk, it is remembering
# that the attribute for a structural diff is `difftastic` and that the one for
# a QR code is `qrencode`; a curated name and one sentence of reason recover
# that in a second. Nothing needs a return path either, because `nix run`
# leaves no garbage-collector root, so what is launched here and never launched
# again is reclaimed by `atyrode clean` without anyone tracking it.
#
# `systems` is the fleet's three systems intersected with the package's real
# `meta.platforms`, so the surface never offers an entry that cannot run where
# it is read. macOS applications are Homebrew casks in
# `modules/darwin/casks.nix` and are never ephemeral, which is why a
# darwin-absent entry belongs here as a Linux-only one rather than as a cask.
let
  everywhere = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
  linuxOnly = [
    "x86_64-linux"
    "aarch64-linux"
  ];
in
{
  bpftrace = {
    attribute = "bpftrace";
    reason = "Trace what the kernel is doing to a process without building a probe.";
    systems = linuxOnly;
  };
  difftastic = {
    attribute = "difftastic";
    reason = "Diff two files by syntax when a line diff is unreadable.";
    systems = everywhere;
  };
  graphviz = {
    attribute = "graphviz";
    reason = "Render a dot graph to an image.";
    systems = everywhere;
  };
  hyperfine = {
    attribute = "hyperfine";
    reason = "Benchmark two commands against each other with real statistics.";
    systems = everywhere;
  };
  imagemagick = {
    attribute = "imagemagick";
    reason = "Convert, crop, or resize an image from the shell.";
    systems = everywhere;
  };
  pandoc = {
    attribute = "pandoc";
    reason = "Convert a document between markup formats.";
    systems = everywhere;
  };
  powertop = {
    attribute = "powertop";
    reason = "Find out what is draining a laptop battery.";
    systems = linuxOnly;
  };
  qrencode = {
    attribute = "qrencode";
    reason = "Turn a string into a QR code a phone can read.";
    systems = everywhere;
  };
  tcpdump = {
    attribute = "tcpdump";
    reason = "Capture packets when a service is silent and the logs are not.";
    systems = everywhere;
  };
  tokei = {
    attribute = "tokei";
    reason = "Count the lines of a tree by language.";
    systems = everywhere;
  };
  yt-dlp = {
    attribute = "yt-dlp";
    reason = "Download a video or its audio track for offline use.";
    systems = everywhere;
  };
}
