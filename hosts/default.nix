{
  "alex-aarch64-darwin" = {
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
      "desktop"
      "mobile"
      "media"
      "containers"
    ];
  };

  "alex-aarch64-linux" = {
    description = "Headless arm64 Linux development machine with agent tooling";
    system = "aarch64-linux";
    platform = "linux";
    activation = "home-manager";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
    ];
  };

  "alex-x86_64-linux" = {
    description = "Headless x86_64 Linux development machine with agent tooling";
    system = "x86_64-linux";
    platform = "linux";
    activation = "home-manager";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "containers"
    ];
  };

  "alex-x86_64-linux-desktop" = {
    description = "x86_64 Linux workstation adding the desktop, mobile, media, and container stack";
    system = "x86_64-linux";
    platform = "linux";
    activation = "home-manager";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "desktop"
      "mobile"
      "media"
      "containers"
    ];
  };

  "alex-x86_64-linux-wsl" = {
    description = "NixOS-WSL development environment and control plane for the home Windows workstation";
    system = "x86_64-linux";
    platform = "linux";
    activation = "nixos-wsl";
    username = "alex";
    homeDirectory = "/home/alex";
    hostname = "atyrode-wsl";
    capabilities = [
      "base"
      "development"
      "agent-tools"
    ];
  };
}
