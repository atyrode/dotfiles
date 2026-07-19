let
  rioLock = builtins.fromJSON (builtins.readFile ../inventory/rio-windows.json);
in
{
  schemaVersion = 2;
  packages = [
    {
      id = "Zen-Team.Zen-Browser.Twilight";
      name = "Zen Browser Twilight";
      source = "winget";
      conflicts = [ "Zen-Team.Zen-Browser" ];
      versionPolicy = "installed; Zen Browser owns its normal update channel";
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
      id = "raphamorim.rio";
      name = "Rio terminal";
      source = "github-release";
      inherit (rioLock) version;
      inherit (rioLock) installer config;
      versionPolicy = "pinned to the nixpkgs pin";
      mutableStateOwner = "Rio owns its runtime state; Nix owns the config artifact";
    }
  ];
}
