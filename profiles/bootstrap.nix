{
  "development-aarch64-linux" = {
    description = "Portable headless arm64 Linux development environment with agent tooling";
    system = "aarch64-linux";
    platform = "linux";
    activation = "home-manager";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
    ];
  };

  "development-x86_64-linux" = {
    description = "Portable headless x86_64 Linux development environment with agent tooling";
    system = "x86_64-linux";
    platform = "linux";
    activation = "home-manager";
    capabilities = [
      "base"
      "development"
      "agent-tools"
      "security"
      "containers"
    ];
  };
}
