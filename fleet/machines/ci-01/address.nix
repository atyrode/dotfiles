# Where this machine is, as two facts of different kinds; see
# ../dev-01/address.nix for why both are public here.
#
# `domain` is how the fleet reaches it: `ci-01.<domain>` has to resolve.
#
# Everything below `domain` is what the machine's own uplink is configured
# with, read by `network.nix`.
{
  domain = "tyrode.dev";

  mac = "2a:62:2f:c3:83:ae";
  ipv4 = "62.83.139.95";
  ipv4PrefixLength = 22;
  ipv4Gateway = "62.83.136.1";
  ipv6 = "2a03:4000:1b:1288:2862:2fff:fec3:83ae";
  ipv6PrefixLength = 64;
  ipv6Gateway = "fe80::1";
}
