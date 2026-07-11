{
  "alex-aarch64-darwin" = {
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
