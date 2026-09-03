# The bearer token of the fleet's one OMP authentication broker, minted by clan
# rather than by the broker and carried by no vault (ADR 0008 amendment,
# secrets row). One shared value, because the broker and every client of it
# must present the same string: the broker checks requests against it, the
# clients send it. sops-nix places it at activation on every clan machine,
# owned by the account that runs the agent stack, and Home Manager links the
# file OMP reads to the placed one, so `omp auth-broker serve` finds the token
# where it would have minted its own and never mints, and every client
# resolves it from the same path when no environment variable overrides it.
#
# Which machine serves is one fact, fleet/auth-broker.json, and the module
# decides each machine's role from it: the named host runs the broker, every
# other machine keeps an SSH local-forward to it. The SSH target is derived the
# way clan reaches that machine -- `<username>@<hostname>.<domain>` from the
# registry and the machine's own address.nix, exactly as modules/nixos/vps.nix
# derives `targetHost` -- so moving the broker is one line here and no other
# module ever names a host.
{
  config,
  lib,
  _class,
  ...
}:
let
  user = lib.head (lib.attrNames config.home-manager.users);
  machine = config.clan.core.settings.machine.name;
  group = if _class == "darwin" then "staff" else "users";

  inventory = lib.importJSON ../../fleet/auth-broker.json;
  hosts = import ../../fleet/hosts.nix;
  broker =
    hosts.${inventory.host}
      or (throw "fleet/auth-broker.json names ${inventory.host}, which fleet/hosts.nix does not register");
  brokerAddress = import (../../fleet/machines + "/${inventory.host}/address.nix");
  target = "${broker.username}@${broker.hostname}.${brokerAddress.domain}";

  # Stated from sops-nix's fixed layout rather than read from clan, for the
  # reason babel-archive.nix gives: clan reports a path only once the value
  # exists, and the readers below need it at evaluation. Asserted against
  # clan's answer once there is one.
  placed = "/run/secrets/vars/omp-auth-broker/token";
  reported = config.clan.core.vars.generators.omp-auth-broker.files."token".path;
in
{
  assertions = [
    {
      assertion = inventory.schemaVersion == 1;
      message = "fleet/auth-broker.json has an unsupported schemaVersion";
    }
    {
      assertion = reported == "/no-such-path" || reported == placed;
      message = "omp-auth-broker expects ${placed}, but sops-nix places it at ${reported}";
    }
  ];

  clan.core.vars.generators.omp-auth-broker = {
    share = true;

    files."token" = {
      secret = true;
      owner = user;
      inherit group;
      mode = "0600";
    };

    # 32 random bytes as hex: the same entropy the broker mints for itself,
    # from the kernel and coreutils alone, because clan puts only the declared
    # inputs and coreutils on the generator's PATH. Regenerating rotates the
    # whole fleet at once, which is the only rotation that makes sense for a
    # value every machine must agree on.
    script = ''
      od -An -v -tx1 -N32 /dev/urandom | tr -d ' \n' >"$out/token"
      printf '\n' >>"$out/token"
    '';
  };

  # OMP reads ~/.omp/auth-broker.token (its configuration root for the default
  # profile, one level above the agent directory) and nothing else, on both
  # sides of the broker. An out-of-store link keeps the token where sops-nix
  # placed it, mode 0600 and never in the Nix store; until the value is
  # generated the link dangles, which the supervisor, `code`, and doctor all
  # read as "not yet placed". A shared module rather than `users.<name>`, for
  # the reason babel-archive.nix gives: naming the user here would read the
  # very attribute set this defines.
  home-manager.sharedModules = [
    (
      { config, ... }:
      {
        home.file.".omp/auth-broker.token".source = config.lib.file.mkOutOfStoreSymlink placed;
        # The role and target reach the supervisor as options of the agent
        # stack's module, so the mode is never read from a file at run time.
        # Every clan machine of this fleet carries that stack; one that did
        # not would have no OMP to hand a token to, and fails evaluation here.
        atyrode.agentTools.authBroker = {
          role = if machine == inventory.host then "serve" else "tunnel";
          tokenFile = placed;
        }
        // lib.optionalAttrs (machine != inventory.host) { inherit target; };
      }
    )
  ];
}
