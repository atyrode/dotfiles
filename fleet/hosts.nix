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
    ];
  };

  "headless-aarch64-linux" = {
    description = "Shape for a headless arm64 Linux machine with agent tooling";
    system = "aarch64-linux";
    platform = "linux";
    activation = "home-manager";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
    ];
  };

  "platform-01" = {
    description = "The VPS serving the public platform, pending decommission";
    system = "x86_64-linux";
    platform = "linux";
    activation = "home-manager";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
      "containers"
      "manifold-node"
    ];
  };

  "workstation-x86_64-linux" = {
    description = "Shape for an x86_64 Linux workstation with the desktop, mobile, media, and container stack";
    system = "x86_64-linux";
    platform = "linux";
    activation = "home-manager";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
      "desktop"
      "mobile"
      "media"
      "containers"
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
    ];
  };
}
