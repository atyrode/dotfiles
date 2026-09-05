# The Cloudflare API token that edits the tyrode.dev zone, placed by clan on
# the VPS alone. The operator's agents run there, and DNS is the one lever a
# cutover pulls that no repository holds: which host `manifold.tyrode.dev`
# names (manifold's cutover kit, `cutover.sh dns flip|rollback`).
#
# Per machine and prompted, never shared or minted: Cloudflare issues the
# token, scoped to `Zone.DNS: Edit` on that zone and client-IP filtered to
# the VPS's address, so the same string is inert from any other machine, and
# placing it there would be custody without use. The value arrives through
# clan's $prompts file and is never echoed: a paste that is not a token fails
# at the operator's terminal, before anything is encrypted.
{ config, host, ... }:
let
  inherit (host) username;

  # Stated from sops-nix's fixed layout and asserted against clan's answer
  # once there is one, for the reason babel-archive.nix gives.
  placed = "/run/secrets/vars/cloudflare-dns/api-token";
  reported = config.clan.core.vars.generators.cloudflare-dns.files."api-token".path;
in
{
  assertions = [
    {
      assertion = reported == "/no-such-path" || reported == placed;
      message = "cloudflare-dns expects ${placed}, but sops-nix places it at ${reported}";
    }
  ];

  clan.core.vars.generators.cloudflare-dns = {
    prompts."api-token" = {
      description = "the Cloudflare API token for the tyrode.dev zone (Zone.DNS: Edit, client IP filtered to this machine)";
      type = "hidden";
    };

    files."api-token" = {
      secret = true;
      owner = username;
      group = "users";
      mode = "0600";
    };

    # A Cloudflare API token is one line of URL-safe characters. Anything
    # else is a paste that went wrong -- a header, a JSON envelope, an empty
    # line -- and it is refused here without being quoted. bash and
    # coreutils are all the generator has, so the test is the shell's own.
    script = ''
      token=$(tr -d '\n' <"$prompts/api-token")
      [[ "$token" =~ ^[A-Za-z0-9_-]{32,}$ ]] ||
        { echo "cloudflare-dns: api-token is not a Cloudflare API token" >&2; exit 1; }
      printf '%s\n' "$token" >"$out/api-token"
    '';
  };

  # Readers look in ~/.config/cloudflare/api-token, the path the cutover kit
  # and any Cloudflare tool on the machine already use. An out-of-store link
  # keeps the token where sops-nix placed it, mode 0600 and never in the Nix
  # store; until the value is generated the link dangles, which every reader
  # sees as "no token", the same state as before.
  home-manager.users.${username} =
    { config, ... }:
    {
      xdg.configFile."cloudflare/api-token".source = config.lib.file.mkOutOfStoreSymlink placed;
    };
}
