# One sentence per capability, printed by `atyrode capabilities`. The set of
# capabilities is declared in modules/home/profiles/default.nix; lib/targets.nix
# asserts that this file names exactly those, so a capability cannot be added
# without saying what it is for.
{
  agent-tools = "Codex, OMP, managed agents, and their configuration";
  base = "Shell, Git/GitHub, search, direnv, mise, on-demand lookup, diagnostics, and Home Manager";
  containers = "Container clients and inspection tools; the daemon stays system-owned";
  desktop = "Operator-selected graphical applications";
  development = "Cross-repository Nix, shell, and workflow quality tools, not project language runtimes";
  media = "Audio and video conversion and inspection";
  manifold-node = "Fleet agent joining this machine to the self-hosted manifold hub";
  mobile = "Android device tooling";
  security = "Declared scanning and network diagnostics";
}
