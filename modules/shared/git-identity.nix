# The Git keys of a clan machine, minted by clan rather than fetched from a
# vault. Two keys, because authentication and signature are different powers:
# one opens a forge, the other says a commit is the operator's. Both are
# per-machine and never shared, so revoking a machine is deleting one
# registration rather than rotating the fleet's single key.
#
# The private halves are secrets: sops-nix places them at activation, owned by
# the account that uses them. The public halves are ordinary values in the
# repository, which is what makes the signer set reviewable -- a new signing
# key is trusted only when a commit adds it to modules/home/git/allowed-signers,
# and checks/fleet/git-identity.nix fails while a generated key is missing from
# that file.
{
  config,
  lib,
  pkgs,
  _class,
  ...
}:
let
  # The account these keys belong to is the one this machine deploys a home
  # for; every clan machine in this fleet has exactly one.
  user = lib.head (lib.attrNames config.home-manager.users);
  machine = config.clan.core.settings.machine.name;
in
{
  clan.core.vars.generators.git-identity = {
    files."auth-key" = {
      secret = true;
      owner = user;
      group = if _class == "darwin" then "staff" else "users";
      mode = "0600";
    };
    files."auth-key.pub".secret = false;
    files."signing-key" = {
      secret = true;
      owner = user;
      group = if _class == "darwin" then "staff" else "users";
      mode = "0600";
    };
    files."signing-key.pub".secret = false;

    runtimeInputs = [ pkgs.openssh ];

    # ssh-keygen writes the public half beside the private one under exactly
    # the names declared above. The comment names the machine because that is
    # what an operator reads in a forge's key list and in allowed-signers.
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C "alex@tyrode.dev (${machine} auth)" -f "$out/auth-key"
      ssh-keygen -q -t ed25519 -N "" -C "alex@tyrode.dev (${machine} signing)" -f "$out/signing-key"
    '';
  };
}
