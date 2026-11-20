# Only public topology and peer keys belong here. Windows and iPhone generate
# their private keys in the native WireGuard clients; null means not enrolled.
let
  network = builtins.fromJSON (builtins.readFile ./machines/dev-01/tern-network.json);

  generatedKey =
    machine:
    let
      path = ../vars/per-machine + "/${machine}/tern-workspace-wireguard/publickey/value";
      match = builtins.match "([A-Za-z0-9+/]{43}=)\n?" (builtins.readFile path);
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
  serverPublicKey = generatedKey "dev-01";
  peers = {
    macbook = {
      address = network.clients.macbook;
      publicKey = generatedKey "macbook";
    };
    windows = {
      address = network.clients.windows;
      publicKey = "wnyugZMgI7mxhMyHJm8hi2KP4ULgyNlVyWFisjAuhAo=";
    };
    iphone = {
      address = network.clients.iphone;
      publicKey = null;
    };
  };
}
