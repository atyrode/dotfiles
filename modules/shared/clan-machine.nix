# What every clan machine in this fleet takes back from, or adds to, clan's
# machine defaults (ADR 0008 amendment). The darwin and nixos classes evaluate
# this same module; the one class-specific attribute is selected by `_class`
# because it does not exist as an option on the other class.
#
# The machine's age key is minted on the machine by `atyrode identity init`
# and never travels; clan records only the public half under
# sops/machines/<name>/key.json. Clan only points sops-nix at the key when it
# generated the key itself, so the path is named here for both classes: it is
# the same fact `atyrode identity` writes to, and the two must agree. SSH host
# keys are deliberately not identities: a host key changes when sshd is
# reinstalled and is harder to revoke than a recipient the ceremony printed,
# so both derivations sops-nix offers are switched off rather than defaulted.
{ _class, lib, ... }:
{
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = [ ];
  };
  sops.gnupg.sshKeyPaths = [ ];

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
