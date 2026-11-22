# Pure topology of the private Tern host on WSL, shared by the network guard
# and the runtime. The addresses are the fleet overlay's own: clan places a
# peer at `<controller prefix>:<peer suffix>`, so both are read from the vars
# that generate them and never restated. The Mac's Tern key is the one already
# enrolled in `tern-workspace.nix`; nothing here adds an authenticator.
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
      throw "WSL Tern host needs ${machine}/${generator}/${file}; run `clan vars generate ${machine}`.";

  # Clan's wireguard service allocates peers in the sole controller's prefix.
  prefix = var "dev-01" "wireguard-network-fleet" "prefix";
  overlayAddress = machine: "${prefix}:${var machine "wireguard-network-fleet" "suffix"}";

  clientPublicKey = (import ./tern-workspace.nix).peers.macbook.nativePublicKey;
in
assert
  clientPublicKey != null
  || throw "The Mac's native Tern public key is not enrolled in fleet/tern-workspace.nix.";
{
  interface = "fleet";
  port = 944;
  address = overlayAddress "wsl";
  clientAddress = overlayAddress "macbook";
  inherit clientPublicKey;
  hostname = "wsl.fleet";
}
