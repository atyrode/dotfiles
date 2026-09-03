# What every clan machine in this fleet takes back from, or adds to, clan's
# machine defaults (ADR 0008 amendment). The darwin and nixos classes evaluate
# this same module; the one class-specific attribute is selected by `_class`
# because it does not exist as an option on the other class.
#
# The machine's age key is clan's: `clan vars generate` mints it on an
# operator device and keeps its private half in the repository, encrypted to
# the admins group, under sops/secrets/<name>-age.key. Clan places it at the
# path below when it deploys a machine, and `atyrode apply` places it there
# on the machine the operator sits on; the path is stated here so both agree
# with sops-nix on where the key is. SSH host keys are deliberately not
# identities: a host key changes when sshd is reinstalled and is harder to
# revoke than a recipient, so both derivations sops-nix offers are switched
# off rather than defaulted.
#
# Every value clan generates is encrypted to the admins group by default:
# the group is the operator, one member per device the operator works from,
# plus the break-glass recovery key.
{ _class, lib, ... }:
{
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = [ ];
  };
  sops.gnupg.sshKeyPaths = [ ];
  clan.core.sops.defaultGroups = [ "admins" ];

  # clanCore's "recommended defaults" add debugging packages (tcpdump,
  # dnsutils, htop, jq, curl, git, nixos-facter), networkd, mDNS, and nix
  # daemon scheduling. This repository owns the package set and the nix
  # settings; the host modules already declare what each machine needs.
  clan.core.enableRecommendedDefaults = false;
}
// lib.optionalAttrs (_class == "darwin") {
  # clan defaults `networking.hostName` to the machine name; nix-darwin then
  # rewrites the Mac's HostName at activation. The Mac keeps the name it has,
  # as before the fold.
  networking.hostName = lib.mkOverride 999 null;
}
// lib.optionalAttrs (_class == "nixos") {
  # clanCore/zfs.nix defaults `networking.hostId` to the install-ISO value so
  # ZFS pools import without force; that writes /etc/hostid. No NixOS machine
  # here has a ZFS pool or had a hostid, so it keeps not having one.
  networking.hostId = lib.mkOverride 999 null;
}
