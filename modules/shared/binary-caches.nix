# The binary cache every fleet machine substitutes from: the official cache.
# The lists are derived from the reviewed system boundary rather than restated,
# so nix-darwin, NixOS-WSL, the system-boundary check and `doctor` cannot drift
# from one another: changing the inventory changes all of them at once.
let
  boundary = builtins.fromJSON (builtins.readFile ../../fleet/system-boundary.json);
in
{
  substituters = [ boundary.nix.substituter ];
  trusted-public-keys = [ boundary.nix.trustedPublicKey ];
}
