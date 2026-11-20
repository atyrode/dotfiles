{
  schemaVersion = 2;
  packages = [
    {
      id = "Zen-Team.Zen-Browser.Twilight";
      name = "Zen Browser Twilight";
      installVersion = "1.23t";
      source = "winget";
      conflicts = [ "Zen-Team.Zen-Browser" ];
      versionPolicy = "install 1.23t; Zen Browser owns normal updates";
      mutableStateOwner = "Zen Browser owns its Mozilla account, profile, cookies, sessions, updates, and caches";
    }
    {
      id = "DEVCOM.JetBrainsMonoNerdFont";
      name = "JetBrainsMono Nerd Font";
      source = "winget";
      conflicts = [ ];
      versionPolicy = "installed; WinGet owns normal font updates";
      mutableStateOwner = "Windows owns the installed font files; Nix owns package presence";
    }
    {
      id = "WireGuard.WireGuard";
      name = "WireGuard";
      source = "winget";
      conflicts = [ ];
      versionPolicy = "installed; WireGuard owns normal updates";
      mutableStateOwner = "Windows keeps the private key; atyrode manages only the dedicated Tern tunnel";
    }
  ];
}
