{
  "macbook" = {
    description = "Primary Apple Silicon Mac with the full development, agent, and desktop stack";
    system = "aarch64-darwin";
    platform = "darwin";
    activation = "nix-darwin";
    username = "alex";
    homeDirectory = "/Users/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
      "desktop"
      "mobile"
      "media"
      "containers"
      "manifold-node"
    ];
  };

  "wsl" = {
    description = "NixOS-WSL development environment and control plane for the home Windows workstation";
    system = "x86_64-linux";
    platform = "linux";
    activation = "nixos-wsl";
    username = "alex";
    homeDirectory = "/home/alex";
    hostname = "wsl";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
      "manifold-node"
    ];
  };

  "dev-01" = {
    description = "Persistent, rebuildable personal development VPS";
    system = "x86_64-linux";
    platform = "linux";
    activation = "nixos";
    username = "alex";
    homeDirectory = "/home/alex";
    hostname = "dev-01";
    # The Nix daemon trusts the operator explicitly because clan copies a
    # closure to this machine before activation escalates, and passwordless
    # sudo already makes that account root-equivalent.
    nixTrustedUsers = [
      "root"
      "alex"
    ];
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
      "containers"
      # A spoke of the stable manifold hub (fleet/manifold.json), like every
      # machine here; this one also hosts the development hub, which is
      # Docker and a Caddy front (modules/nixos/manifold-dev-hub.nix), not a
      # capability. The old infra closure got the agent from the server
      # profile; the entry that replaced it (#516) had dropped it.
      "manifold-node"
    ];
  };
}
