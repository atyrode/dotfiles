{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  # Home Manager passes `osConfig` as a special argument only when the
  # profile is embedded in a nixos or nix-darwin configuration; a module
  # argument with a default would still be looked up and fail, so it is read
  # from the argument set instead. The `clan` option tree exists only where
  # clanCore is imported, which is what makes a system a clan machine.
  clanMachine = (args.osConfig or { }) ? clan;
in
{
  # Antivirus requires system-owned signature updates and a scanning workflow.
  # No registered host has that policy, so ClamAV is intentionally absent.
  #
  # sops is what a machine uses to inspect what activation decrypted for it
  # and the crypto behind every `clan secrets`/`clan vars` call
  # (docs/secrets.md), so every fleet member carries it. age-plugin-se holds
  # the operator's daily identity in the Mac's Secure Enclave. Every clan
  # machine is also an operator device and so encrypts to that enclave
  # recipient whenever it writes a value, but the plugin's Linux closure is a
  # Swift runtime that drags a full clang (2.1 GiB against 88 MiB for sops),
  # so on Linux the atyrode ceremonies that write secrets fetch it into a
  # transient nix shell around clan (clan_write in pkgs/atyrode/lib/core.sh)
  # rather than every profile carrying it. It is installed only where the
  # enclave is. The clan CLI is installed exactly where clan-core built the
  # system this profile is embedded in: a portable Home Manager profile and a
  # client's NixOS machine consuming it are not clan machines, so neither
  # carries a fleet CLI it cannot use.
  home.packages =
    (with pkgs; [
      nmap
      socat
      sops
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.age-plugin-se ]
    ++ lib.optionals clanMachine [ pkgs.clan-cli ];

  # sops looks for its default identity under the platform's user
  # configuration directory, which on macOS is ~/Library/Application Support
  # unless XDG_CONFIG_HOME is exported, and this configuration exports no such
  # thing. `atyrode operator init` writes the key under ~/.config on every
  # platform, so sops is pointed at that same file everywhere rather than at
  # a path that differs by operating system.
  home.sessionVariables.SOPS_AGE_KEY_FILE = "${config.xdg.configHome}/sops/age/keys.txt";
}
