# Where this machine is, as two facts of different kinds; see
# ../dev-01/address.nix for why both are public here.
#
# `domain` is how the fleet reaches it: `ci-01.<domain>` has to resolve.
#
# The uplink below is read by `network.nix`. The runner module also reads the
# reserved destination ranges for this machine's job egress policy.
{
  domain = "tyrode.dev";

  mac = "2a:62:2f:c3:83:ae";
  ipv4 = "62.83.139.95";
  ipv4PrefixLength = 22;
  ipv4Gateway = "62.83.136.1";
  ipv6 = "2a03:4000:1b:1288:2862:2fff:fec3:83ae";
  ipv6PrefixLength = 64;
  ipv6Gateway = "fe80::1";

  blockedJobIPv4 = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
  blockedJobIPv6 = [
    "fc00::/7"
    "fe80::/10"
  ];
}
