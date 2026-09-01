# The binary caches every fleet machine substitutes from, in the order Nix
# tries them: the official cache first, because it answers for almost every
# path, and the fleet cache second for the host closures CI built. The lists
# are derived from the reviewed system boundary rather than restated, so
# nix-darwin, NixOS-WSL, the system-boundary check and `doctor` cannot drift
# from one another: changing the inventory changes all of them at once.
let
  boundary = builtins.fromJSON (builtins.readFile ../inventory/system-boundary.json);
in
{
  substituters = [
    boundary.nix.substituter
    boundary.nix.fleetCache.substituter
  ];
  trusted-public-keys = [
    boundary.nix.trustedPublicKey
    boundary.nix.fleetCache.trustedPublicKey
  ];
}
