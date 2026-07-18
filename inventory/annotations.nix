{
  schemaVersion = 1;

  capabilities = {
    agent-tools = {
      title = "Agent tools";
      purpose = "Codex, OMP, herdr, managed agents, and their configuration";
      consumer = "Claude Code, Codex, OMP isolation, and TUI verification";
      group = "automation";
      deliveryBoundary = "Home Manager packages and repository overlays";
      mutableState = "Harness-owned authentication, sessions, MCP state, and caches remain in the user home";
      securityBoundary = "The inventory describes installed tools only; it never reads agent credentials or sessions";
    };
    base = {
      title = "Base";
      purpose = "Shell, Git/GitHub, search, direnv, mise, on-demand lookup, diagnostics, and Home Manager";
      consumer = "Operator and agent shell baseline";
      group = "core";
      deliveryBoundary = "Home Manager";
      mutableState = "Tool-specific XDG caches only";
      securityBoundary = "No credentials or mutable shell state are inventoried";
    };
    containers = {
      title = "Containers";
      purpose = "Container clients and inspection tools; the daemon stays system-owned";
      consumer = "Containerized project and server operations";
      group = "development";
      deliveryBoundary = "Home Manager owns clients; the operating system owns the daemon";
      mutableState = "Daemon-owned images and volumes remain outside Home Manager";
      securityBoundary = "Daemon privileges and sockets are system-owned prerequisites";
    };
    desktop = {
      title = "Desktop";
      purpose = "Operator-selected graphical applications";
      consumer = "Interactive workstation use";
      group = "desktop";
      deliveryBoundary = "Home Manager on Linux; nix-darwin manages pinned Homebrew casks on macOS";
      mutableState = "Applications own their user data and caches";
      securityBoundary = "Application accounts and credentials are not evaluated";
    };
    development = {
      title = "Development";
      purpose = "Cross-repository Nix and shell quality tools, not project language runtimes";
      consumer = "Cross-repository agent linting, Nix editing, and operator deployment CLIs";
      group = "development";
      deliveryBoundary = "Home Manager; project runtimes remain project-owned";
      mutableState = "Language-server caches only";
      securityBoundary = "Project toolchains are intentionally excluded from the global inventory";
    };
    media = {
      title = "Media";
      purpose = "Audio and video conversion and inspection";
      consumer = "Desktop media workflows";
      group = "desktop";
      deliveryBoundary = "Home Manager";
      mutableState = "None beyond operator-selected project files";
      securityBoundary = "Media contents are never inspected";
    };
    mobile = {
      title = "Mobile";
      purpose = "Android device tooling";
      consumer = "Interactive Android device workflows";
      group = "development";
      deliveryBoundary = "Home Manager owns clients; devices remain external";
      mutableState = "ADB host keys and device state remain mutable and are not inventoried";
      securityBoundary = "Device identities and ADB keys are excluded";
    };
    security = {
      title = "Security";
      purpose = "Declared scanning and network diagnostics";
      consumer = "Operator-directed diagnostics";
      group = "operations";
      deliveryBoundary = "Home Manager";
      mutableState = "Tool-specific caches only";
      securityBoundary = "Targets, scan results, and network state are never evaluated";
    };
    server = {
      title = "Server";
      purpose = "Linux-only marker for the reviewed headless composition";
      consumer = "Portable server profiles";
      group = "operations";
      deliveryBoundary = "Marker capability; base and agent-tools deliver its user packages";
      mutableState = "System and service state remain owned by the consuming NixOS configuration";
      securityBoundary = "The marker deliberately contributes no package and carries no production facts";
      platforms = [ "linux" ];
    };
  };

  # These are intentional boundaries, not evaluated package membership.
  externalItems = {
    projectOwned = {
      kind = "on-demand";
      items = [
        "bun"
        "cargo"
        "clippy"
        "deno"
        "gcc"
        "go"
        "nodejs"
        "pillow"
        "python"
        "rust-analyzer"
        "rustc"
        "rustfmt"
        "uv"
      ];
      purpose = "Runtimes and compilers belong to committed project shells, mise.toml, or native manifests";
    };
    experimental = {
      kind = "not-installed";
      items = [
        "pi"
        "pi-extensions"
        "zed"
      ];
      purpose = "Candidates remain absent until separately evaluated and admitted";
    };
  };

  # nix-darwin currently owns this evaluated cask set as one system boundary.
  # Desktop is the demonstrated consumer; individual cask names stay generated.
  homebrewCaskOwner = "desktop";
}
