# One-line "contains/installs" summary per capability, surfaced by
# `atyrode capabilities`, the bootstrap preset picker, and flake consumers.
# Keys must match ./default.nix exactly; the flake asserts the correspondence.
{
  agent-tools = "Codex, OMP, managed agents, and their configuration";
  base = "shell, Git/GitHub, search, direnv/nix-direnv, mise, on-demand lookup, diagnostics, and Home Manager itself";
  containers = "container clients and inspection tools; the daemon stays system-owned";
  desktop = "operator-selected graphical applications";
  development = "cross-repository Nix and shell quality tools, not project language runtimes";
  media = "audio/video conversion and inspection";
  mobile = "Android device tooling";
  security = "declared scanning and network diagnostics";
  server = "marker for a Linux-only headless composition; the portable server combines it with base and agent-tools";
}
