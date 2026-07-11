{
  "alex-aarch64-darwin" = {
    description = "Primary Apple Silicon Mac with the full development, agent, and desktop stack";
    system = "aarch64-darwin";
    platform = "darwin";
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
    aliases = [ "alex-darwin" ];
  };

  "alex-x86_64-darwin" = {
    description = "Intel Mac variant of the primary Mac profile";
    system = "x86_64-darwin";
    platform = "darwin";
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
    aliases = [ ];
  };

  "alex-aarch64-linux" = {
    description = "Headless arm64 Linux development machine with agent tooling";
    system = "aarch64-linux";
    platform = "linux";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
    ];
    aliases = [ ];
  };

  "alex-x86_64-linux" = {
    description = "Headless x86_64 Linux development machine with agent tooling";
    system = "x86_64-linux";
    platform = "linux";
    username = "alex";
    homeDirectory = "/home/alex";
    capabilities = [
      "base"
      "development"
      "agent-tools"
    ];
    aliases = [
      "alex"
      "alex-linux"
    ];
  };

  "alex-x86_64-linux-desktop" = {
    description = "x86_64 Linux workstation adding the desktop, mobile, media, and container stack";
    system = "x86_64-linux";
    platform = "linux";
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
    aliases = [ "alex-linux-desktop" ];
  };
}
