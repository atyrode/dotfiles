{ lib, pkgs, ... }:

let
  # launchd agents do not inherit SSH_AUTH_SOCK. macOS publishes the per-user
  # agent socket in the launchd environment instead, so read it back from there;
  # without it ssh-add exits 2 with "Could not open a connection to your
  # authentication agent". The socket is owned by a separate launchd job, so poll
  # briefly rather than assuming it already exists at login.
  loadKeychainKeys = pkgs.writeShellScript "ssh-load-keychain-keys" ''
    for _ in $(seq 1 15); do
      socket="$(/bin/launchctl getenv SSH_AUTH_SOCK || true)"
      if [ -n "$socket" ] && [ -S "$socket" ]; then
        SSH_AUTH_SOCK="$socket" exec /usr/bin/ssh-add --apple-load-keychain
      fi
      sleep 2
    done
    echo "ssh-agent socket never appeared; leaving the agent unpopulated" >&2
    exit 0
  '';
in
{
  # Git signs every commit with an SSH key (`commit.gpgsign`, `gpg.format = ssh`).
  # `ssh-keygen -Y sign` does not read ssh_config, so it cannot pull a passphrase
  # out of the Keychain itself; it can only sign without prompting when the key is
  # already loaded in ssh-agent. macOS starts a per-user agent but leaves it empty,
  # so a fresh login turns every commit into a passphrase prompt even though the
  # passphrase is sitting in the Keychain.
  #
  # `ssh-add --apple-load-keychain` adds every key whose passphrase is stored in
  # the Keychain without prompting, which restores the behaviour the agent is
  # generally assumed to have.
  launchd.agents.ssh-load-keychain-keys = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${loadKeychainKeys}" ];
      RunAtLoad = true;
      # Deliberately no ProcessType. "Background" runs the job outside the
      # interactive security session, where ssh-add reaches no Keychain-stored
      # passphrase and exits 0 having added nothing.
    };
  };

  # Keep the Keychain populated going forward: a key unlocked once is stored and
  # added to the agent on later use, so the job above has something to load.
  # UseKeychain is macOS-only and makes ssh reject the config elsewhere.
  programs.ssh = lib.mkIf pkgs.stdenv.isDarwin {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      AddKeysToAgent = "yes";
      UseKeychain = "yes";
    };
  };
}
