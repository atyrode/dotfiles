# Where this machine is, as two facts of different kinds.
#
# `domain` is how the fleet reaches it: deployment and anything else that has
# to find the machine resolve `<hostname>.<domain>`, so rehosting costs one DNS
# record and no commit. Clan's own default for `targetHost` is a fully
# qualified name for that reason. The record has to exist -- a machine whose
# name does not resolve fails `atyrode fleet plan` at the reachability step,
# which is the honest place to find out.
#
# Everything below `domain` is what the machine's own uplink is configured
# with, and it is a different category: a hosting fact of the same kind as the
# disk named in `disko.nix` and the hardware in `facter.json`, read at
# evaluation time by `network.nix`, which is the only reader. These cannot be
# secrets even if one wanted them to be -- sops-nix decrypts at activation and
# Nix finished evaluating long before that -- and they are stated once, here,
# so no module under `modules/` ever names a fact about one machine.
# `checks/lints/production-facts.nix` holds the reasoning for why publishing
# them is not what protects it.
{
  domain = "tyrode.dev";

  mac = "e6:fa:af:f1:7b:6a";
  ipv4 = "152.53.112.19";
  ipv4PrefixLength = 22;
  ipv4Gateway = "152.53.112.1";
  ipv6 = "2a0a:4cc0:80:41e4:e4fa:afff:fef1:7b6a";
  ipv6PrefixLength = 64;
  ipv6Gateway = "fe80::1";
}
