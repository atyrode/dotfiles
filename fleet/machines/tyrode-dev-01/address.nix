# Where this machine answers. The address lives here rather than beside the
# policy in `modules/nixos/` because `fleet/machines/<host>/` is the one place
# in this public repository where a machine states its own facts, and a policy
# module that named an address would be naming a fact about one machine in the
# file that describes what every machine of this shape does.
# `checks/lints/production-facts.nix` holds the reasoning for why publishing it
# is not what protects the machine.
{
  ipv4 = "152.53.112.19";
}
