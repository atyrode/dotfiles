# The Manifold machine token of a clan machine, placed by clan rather than
# minted on the machine from a vault session (ADR 0008 amendment, secrets
# row). Two generators, because the values have two lifetimes and two
# audiences:
#
#   manifold-custody is shared and holds the hub's owner key, the one value
#   only the operator can supply: it is root on the hub, is read once at
#   `clan vars generate`, and is never deployed. It exists so that an operator
#   device can enroll a machine without the operator fetching the key by hand
#   each time, and so that no machine of the fleet ever holds it.
#
#   manifold-agent is per machine and holds the token the hub minted for this
#   machine. Enrollment is an HTTP call, and a generator runs without a
#   network, so the token cannot be minted here: `atyrode runtime enroll
#   manifold-agent <host>` on an operator device asks the hub and stores the
#   answer with `clan vars set`. The prompt exists for the operator who has a
#   token in hand and no CLI; its description says which command to prefer.
#   sops-nix places the token at activation, owned by the account whose agent
#   reads it, and Home Manager links ~/.config/manifold/machine.token to the
#   placed file, so the native units and `atyrode runtime` read it where they
#   always have. Until the value exists the link dangles, which the units'
#   path conditions read as "not enrolled", the same inert state as before.
#
# The link is forced over a pre-existing regular file because the machines
# enrolled before this module carry their token as one; the enroll ceremony
# adopts such a file into clan before the apply that replaces it.
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

  inventory = lib.importJSON ../../fleet/manifold.json;
  spoke = builtins.elem machine inventory.spokes;

  # Stated from sops-nix's fixed layout rather than read from clan, for the
  # reason babel-archive.nix gives; asserted against clan's answer once there
  # is one.
  placed = "/run/secrets/vars/manifold-agent/machine-token";
  reported = config.clan.core.vars.generators.manifold-agent.files."machine-token".path;
in
lib.mkIf spoke {
  assertions = [
    {
      assertion = reported == "/no-such-path" || reported == placed;
      message = "manifold-agent expects ${placed}, but sops-nix places it at ${reported}";
    }
  ];

  clan.core.vars.generators.manifold-custody = {
    share = true;

    prompts."owner-key" = {
      description = "the Manifold hub's owner key (MANIFOLD_OWNER_KEY of the deployment named in fleet/manifold.json; existing, never minted here)";
      type = "hidden";
    };

    files."owner-key" = {
      secret = true;
      deploy = false;
    };

    # The hub mints its key as 64 hex characters, so anything else is a paste
    # error and fails here, on the operator's terminal, never at an enrollment
    # the hub then refuses. Only coreutils are on the generator's PATH.
    script = ''
      key="$(tr -d '[:space:]' <"$prompts/owner-key")"
      case "$key" in
        *[!0-9a-fA-F]*) echo "manifold-custody: owner-key is not hexadecimal" >&2; exit 1 ;;
      esac
      [ "''${#key}" -eq 64 ] || { echo "manifold-custody: owner-key is not 64 hex characters" >&2; exit 1; }
      printf '%s\n' "$key" >"$out/owner-key"
    '';
  };

  clan.core.vars.generators.manifold-agent = {
    prompts."machine-token" = {
      description = "the machine token the Manifold hub minted for ${machine}; prefer `atyrode runtime enroll manifold-agent ${machine}` on an operator device, which mints and stores it";
      type = "hidden";
    };

    files."machine-token" = {
      secret = true;
      owner = user;
      inherit group;
      mode = "0600";
    };

    script = ''
      token="$(tr -d '[:space:]' <"$prompts/machine-token")"
      [ -n "$token" ] || { echo "manifold-agent: machine-token is empty" >&2; exit 1; }
      printf '%s\n' "$token" >"$out/machine-token"
    '';
  };

  # A shared module rather than `users.<name>`, for the reason babel-archive.nix
  # gives: naming the user here would read the very attribute set this defines.
  home-manager.sharedModules = [
    (
      { config, ... }:
      {
        home.file.".config/manifold/machine.token" = {
          source = config.lib.file.mkOutOfStoreSymlink placed;
          force = true;
        };
      }
    )
  ];
}
