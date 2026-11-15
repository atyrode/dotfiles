# Caddy's on-demand TLS permission is ONE global `ask` endpoint, yet more
# than one preview tier issues certificates on demand under its own wildcard:
# manifold's `*.manifold.tyrode.dev` and myParcelle's
# `*.preview.myparcelle.tyrode.dev`. Each tier's router alone knows which of
# its names are live. This module owns the global endpoint: a loopback
# dispatcher that forwards each question, unchanged, to the router of the one
# zone that owns the name, and refuses any other name. A tier registers its
# zone below; it never sets `on_demand_tls` itself, so a second tier cannot
# silently replace the first one's gate.
#
# Only names exactly one label deep under a registered zone are forwarded,
# which is all a one-label wildcard site can serve; anything else is refused
# here and costs no certificate.
{ config, lib, ... }:
let
  zones = config.atyrode.caddy.onDemandAsk;
  port = 7899;
  escape = lib.escapeRegex;
  routes = lib.concatStrings (
    lib.imap0 (index: zone: ''
      @zone${toString index} vars_regexp {query.domain} ^[a-z0-9-]+\.${escape zone}$
      handle @zone${toString index} {
        reverse_proxy ${zones.${zone}}
      }
    '') (lib.attrNames zones)
  );
in
{
  options.atyrode.caddy.onDemandAsk = lib.mkOption {
    type = lib.types.attrsOf (lib.types.strMatching "127\\.0\\.0\\.1:[0-9]+");
    default = { };
    example = {
      "manifold.tyrode.dev" = "127.0.0.1:7900";
    };
    description = ''
      DNS zone -> loopback router that answers Caddy's on-demand TLS question
      at `/__preview/ask?domain=<name>` for names one label under that zone.
    '';
  };

  config = lib.mkIf (zones != { }) {
    services.caddy = {
      globalConfig = ''
        on_demand_tls {
          ask http://127.0.0.1:${toString port}/__preview/ask
        }
      '';
      virtualHosts."http://127.0.0.1:${toString port}" = {
        listenAddresses = [ "127.0.0.1" ];
        extraConfig = ''
          ${routes}
          respond 404
        '';
      };
    };
  };
}
