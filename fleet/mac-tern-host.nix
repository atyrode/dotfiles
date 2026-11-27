# Pure topology of the Mac's private Tern host, reached from the Windows
# workstation over the existing dev-01 `fleet` overlay. Addresses come from
# the vars clan generates, never restated. The Windows peer is a restricted
# external one: it is not a clan machine, so it has no generated suffix. Its
# address is reserved here, inside the controller prefix, in a /96 no clan
# peer owns. The checked-in key is public only; the private half stays in the
# native WireGuard client.
let
  trim = builtins.replaceStrings [ "\n" ] [ "" ];
  var =
    machine: generator: file:
    let
      path = ../vars/per-machine + "/${machine}/${generator}/${file}/value";
    in
    if builtins.pathExists path then
      trim (builtins.readFile path)
    else
      throw "Mac Tern host needs ${machine}/${generator}/${file}; run `clan vars generate ${machine}`.";

  prefix = var "dev-01" "wireguard-network-fleet" "prefix";

  # Clan allows each peer the /96 of its prefix plus the first two suffix
  # groups; the reserved Windows address must live in none of them.
  reservedSuffix = "0000:ffff:0000:0002";
  pad = group: builtins.substring (builtins.stringLength group) 4 "0000" + group;
  head96 =
    suffix:
    let
      groups = builtins.filter builtins.isString (builtins.split ":" suffix);
    in
    "${pad (builtins.elemAt groups 0)}:${pad (builtins.elemAt groups 1)}";
  peerSuffixes = map (machine: var machine "wireguard-network-fleet" "suffix") (
    builtins.filter (
      machine:
      machine != "dev-01"
      # ci-01 is not on the overlay and holds no key pair or suffix.
      && builtins.pathExists (../vars/per-machine + "/${machine}/wireguard-network-fleet")
    ) (builtins.attrNames (builtins.readDir ../vars/per-machine))
  );

  tern = import ./tern-workspace.nix;
  clientPublicKey = tern.peers.windows.nativePublicKey;
  endpointDomain = (import ./machines/dev-01/address.nix).domain;
in
assert
  clientPublicKey != null
  || throw "Windows's native Tern public key is not enrolled in fleet/tern-workspace.nix.";
assert
  builtins.all (suffix: head96 suffix != head96 reservedSuffix) peerSuffixes
  || throw "The reserved Windows fleet address overlaps a clan peer's /96.";
{
  interface = "fleet";
  # Unprivileged: the non-root macOS listener cannot bind below 1024.
  port = 9443;
  address = "${prefix}:${var "macbook" "wireguard-network-fleet" "suffix"}";
  clientAddress = "${prefix}:${reservedSuffix}";
  clientWireGuardPublicKey = "g6hXIykTEJri9gr8OaNuVdf05VyffHRkpBsnXI2JWSU=";
  inherit clientPublicKey;
  serverPublicKey = var "dev-01" "wireguard-keys-fleet" "publickey";
  endpoint = "dev-01.${endpointDomain}";
  endpointPort = 51820;
}
