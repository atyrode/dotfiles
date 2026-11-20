{
  config,
  lib,
  ...
}:

let
  workspace = import ../../fleet/tern-workspace.nix;
  peer = workspace.peers.macbook;
  privateKey = config.clan.core.vars.generators.tern-workspace-wireguard.files.privatekey;
  enrolled = peer.publicKey != null && workspace.serverPublicKey != null && privateKey.exists;
in
{
  imports = [ ../shared/tern-workspace-wireguard.nix ];

  config = lib.mkIf enrolled {
    networking.wg-quick.interfaces.${workspace.interface} = {
      address = [ "${peer.address}/32" ];
      privateKeyFile = privateKey.path;
      peers = [
        {
          publicKey = workspace.serverPublicKey;
          endpoint = "${workspace.endpoint}:${toString workspace.port}";
          allowedIPs = [ "${workspace.serverAddress}/32" ];
          persistentKeepalive = 25;
        }
      ];

      # The native PostUp reads this file. Reject a missing or invalid key
      # first, without letting wg's private-key parser log malformed input.
      preUp = ''
        if ! actual=$(wg pubkey 2>/dev/null < ${lib.escapeShellArg privateKey.path}) \
          || [ "$actual" != ${lib.escapeShellArg peer.publicKey} ]; then
          echo "Tern WireGuard: Clan private key is absent or does not match the enrolled Mac key" >&2
          exit 1
        fi
      '';
    };

    # The generated system job already starts at boot. Also restart failed
    # starts, e.g. when sops-nix or DNS is not yet ready.
    launchd.daemons."wg-quick-${workspace.interface}".serviceConfig = {
      KeepAlive = lib.mkForce true;
      EnvironmentVariables.WG_ENDPOINT_RESOLUTION_RETRIES = "0";
    };
  };
}
