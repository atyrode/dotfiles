# How a machine reads the fleet's secrets (ADR 0008). The three activation
# kinds import three different sops-nix modules, but every option this
# repository sets is spelled the same in all of them, so the wiring is written
# once and each constructor only says where that machine's key lives.
#
# The key is an explicit age identity the machine generated for itself
# (`atyrode identity init`), never an SSH host key: a host key changes when
# sshd is reinstalled, is absent on a standalone Home Manager host, and is
# harder to name in `.sops.yaml` than a recipient the ceremony printed. Both
# derivations sops-nix offers are therefore switched off rather than left to
# their defaults.
#
# With no secret declared, sops-nix emits nothing at activation and never
# reads the sops file, so an empty fleet converges on every host before a
# single value has moved. The first declared secret makes the file it names
# load-bearing; a host-specific file is the default when the repository has
# one, the shared file otherwise, and a secret from the other file names its
# `sopsFile` explicitly.
{ hostId, keyFile }:

let
  hostSopsFile = ../../secrets + "/${hostId}.yaml";
in
{
  sops = {
    age = {
      inherit keyFile;
      sshKeyPaths = [ ];
    };
    gnupg.sshKeyPaths = [ ];
    defaultSopsFile =
      if builtins.pathExists hostSopsFile then hostSopsFile else ../../secrets/shared.yaml;
  };
}
