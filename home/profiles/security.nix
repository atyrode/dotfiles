{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Antivirus requires system-owned signature updates and a scanning workflow.
  # No registered host has that policy, so ClamAV is intentionally absent.
  #
  # sops is the editor of secrets/*.yaml (docs/secrets.md) and the reader a
  # machine uses to inspect what activation decrypted for it, so every fleet
  # member carries it. age-plugin-se holds the operator's daily identity in
  # the Mac's Secure Enclave; the plugin builds on Linux too, but its Linux
  # closure is a Swift runtime that drags a full clang (2.1 GiB against 88 MiB
  # for sops), and no Linux host can decrypt as the operator anyway, so it is
  # installed only where the enclave is.
  home.packages =
    (with pkgs; [
      nmap
      socat
      sops
    ])
    ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.age-plugin-se ];

  # sops looks for its default identity under the platform's user
  # configuration directory, which on macOS is ~/Library/Application Support
  # unless XDG_CONFIG_HOME is exported, and this configuration exports no such
  # thing. `atyrode operator init` writes the key under ~/.config on every
  # platform, so sops is pointed at that same file everywhere rather than at
  # a path that differs by operating system.
  home.sessionVariables.SOPS_AGE_KEY_FILE = "${config.xdg.configHome}/sops/age/keys.txt";
}
