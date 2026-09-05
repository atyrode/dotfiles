# The public front of the manifold preview tier on the VPS. Caddy answers
# `preview.manifold.tyrode.dev` -- the integrated instance, every green
# `main`, on the compose stack the operator runs from a checkout on port
# 7912 -- and `*.manifold.tyrode.dev`, one hostname per pull request or live
# worktree, proxied to the operator-owned router on 127.0.0.1:7900 that
# manifold's `infra/previews/preview.sh` generates as previews come and go.
# The stable hub -- `fleet/manifold.json`'s masterUrl -- is elsewhere
# (Clever Cloud, atyrode/manifold ADR 0022); this machine hosts only what
# one iterates on, and is a spoke of the stable one like every other.
#
# Certificates for the wildcard are issued ON DEMAND, per hostname, on first
# request, and only for hostnames the router vouches for (`/__preview/ask`
# answers 200 for a registered preview and 404 otherwise), so a stray name
# under the wildcard never costs a certificate. A DNS-validated wildcard
# certificate would need a DNS plugin and the zone token in Caddy's hands;
# on-demand issuance needs neither.
#
# Ports 80 and 443 are the VPS's reviewed exposure beyond SSH, and exist for
# these vhosts alone: `modules/nixos/vps.nix` opens exactly the set this
# module names. The stacks themselves (images, data volumes, restarts) are
# not declared here: they are the operator's checkouts, started by the
# receiver the deploy key runs (`modules/home/ssh/deploy-keys`), and a vhost
# whose upstream is down answers 502, which is the state "not running" should
# have -- never a fallback to some other hub.
_: {
  services.caddy = {
    enable = true;
    globalConfig = ''
      on_demand_tls {
        ask http://127.0.0.1:7900/__preview/ask
      }
    '';
    virtualHosts."preview.manifold.tyrode.dev".extraConfig = ''
      encode zstd gzip

      header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
      }

      reverse_proxy 127.0.0.1:7912
    '';
    virtualHosts."*.manifold.tyrode.dev".extraConfig = ''
      tls {
        on_demand
      }

      encode zstd gzip

      header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
      }

      reverse_proxy 127.0.0.1:7900
    '';
  };
}
