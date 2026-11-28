# Only public topology and peer keys belong here. Windows, iPhone and Android
# generate their private keys in the native WireGuard clients (Android also
# generates its native SSH key locally); null means not enrolled.
let
  network = builtins.fromJSON (builtins.readFile ./machines/dev-01/tern-network.json);

  # An Ed25519 SSH blob is a framed "ssh-ed25519" string and a framed
  # 32-byte key. The fixed base64 prefix includes the key length; the next
  # character encodes its last bits and the first four bits of the key.
  nativeKeyPattern = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-P][A-Za-z0-9+/]{42}";
  wireguardKeyPattern = "[A-Za-z0-9+/]{43}=";

  matches = pattern: value: builtins.isString value && builtins.match pattern value != null;

  selectNativePeers =
    peers:
    builtins.removeAttrs peers (
      builtins.filter (
        name:
        let
          peer = peers.${name};
        in
        !builtins.isAttrs peer
        || !matches wireguardKeyPattern (peer.publicKey or null)
        || !matches nativeKeyPattern (peer.nativePublicKey or null)
      ) (builtins.attrNames peers)
    );

  generatedKey =
    machine:
    let
      path = ../vars/per-machine + "/${machine}/tern-workspace-wireguard/publickey/value";
      match = builtins.match "(${wireguardKeyPattern})\n?" (builtins.readFile path);
    in
    if !builtins.pathExists path then
      null
    else if match == null then
      throw "Invalid Tern WireGuard public key for ${machine}"
    else
      builtins.head match;
in
{
  hostname = "tern.tyrode.dev";
  endpoint = "dev-01.tyrode.dev";
  interface = "wg-tern";
  port = 51837;
  inherit (network) serverAddress;
  # Reserved listeners prevent an unrelated VPS user from taking either end
  # of the reverse proxy while a service is restarting.
  webPort = 977;
  proxyPort = 943;
  nativePort = 944;
  inherit selectNativePeers;
  serverPublicKey = generatedKey "dev-01";
  peers = {
    macbook = {
      address = network.clients.macbook;
      publicKey = generatedKey "macbook";
      nativePublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMRcKLAXoDVuzSVgqi8KokRBFYMAAj10rpoD5aMdO4Bd";
    };
    windows = {
      address = network.clients.windows;
      publicKey = "wnyugZMgI7mxhMyHJm8hi2KP4ULgyNlVyWFisjAuhAo=";
      nativePublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE46zTCcblt3gILmUZWpus7QtKgfpybAJkL0iH0IabUG";
    };
    iphone = {
      address = network.clients.iphone;
      publicKey = null;
      nativePublicKey = null;
    };
    android = {
      address = network.clients.android;
      publicKey = "Gt1NbaQPM5dRcqf/vGzeP2RZZIROg6g/skttz6czzw8=";
      nativePublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJYqPc8e5hBA8K3l8iuv8rvGeFyCu2B8sgbxv0hD0dU/";
    };
  };
}
