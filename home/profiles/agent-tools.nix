{
  imports = [
    ../../modules/home/agent-tools.nix
    ../codex.nix
    ../packages.nix
  ];

  atyrode.agentTools.enable = true;
}
