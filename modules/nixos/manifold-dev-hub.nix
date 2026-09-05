# The public front of the development manifold hub on the VPS: Caddy answers
# `dev.manifold.tyrode.dev` with a Let's Encrypt certificate and proxies it to
# the compose stack the operator runs from a checkout on port 7912. The
# stable hub -- `fleet/manifold.json`'s masterUrl -- is elsewhere (Clever
# Cloud, atyrode/manifold ADR 0022); this machine hosts only the hub one
# iterates on, and is a spoke of the stable one like every other.
#
# Ports 80 and 443 are the VPS's reviewed exposure beyond SSH, and exist for
# this vhost alone: `modules/nixos/vps.nix` opens exactly the set this module
# names. The stack itself (image, data volume, restarts) is not declared
# here: it is the operator's checkout, started by hand, and a vhost whose
# upstream is down answers 502, which is the state "not running" should
# have -- never a fallback to some other hub.
_: {
  services.caddy = {
    enable = true;
    virtualHosts."dev.manifold.tyrode.dev".extraConfig = ''
      encode zstd gzip

      header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
      }

      reverse_proxy 127.0.0.1:7912
    '';
  };
}
