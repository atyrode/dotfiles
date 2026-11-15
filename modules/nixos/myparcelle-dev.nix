# Only the public edge belongs to the machine. The development checkout owns
# its application and isolated identity service; neither upstream is exposed
# beyond loopback, and an absent checkout answers 502 rather than a fallback.
#
# The application edge is TLS, compression and forwarding, nothing else: the
# application owns caching (fingerprinted assets immutable, documents
# revalidated, invitation shells never stored) and the admin gate on
# /storybook/, exactly as on production. A path block or a cache header here
# made the development surface answer differently from production for no
# reason a reviewer could see (2026-09-07: a 404 on the interface catalog).
#
# Pull-request previews (myParcelle's deploy/README.md § Pull-request
# previews) are `pr-<n>.preview.myparcelle.tyrode.dev`, forwarded whole to the
# loopback router myParcelle's `scripts/preview/` tooling generates on 4300 as
# previews come and go. Certificates are issued on demand, only for names that
# router vouches for. The extra `preview.` label keeps the wildcard off
# `auth.myparcelle.tyrode.dev`: Caddy 2.10+ skips issuing a managed name a
# wildcard site covers, which would leave development sign-in without a
# certificate. DNS: one `*.preview.myparcelle.tyrode.dev` A record.
_: {
  atyrode.caddy.onDemandAsk."preview.myparcelle.tyrode.dev" = "127.0.0.1:4300";

  services.caddy.virtualHosts = {
    "myparcelle.tyrode.dev".extraConfig = ''
      encode zstd gzip
      reverse_proxy 127.0.0.1:4173
    '';
    "auth.myparcelle.tyrode.dev".extraConfig = ''
      @public path /realms/myparcelle/* /resources/* /robots.txt
      handle @public {
        reverse_proxy 127.0.0.1:8082
      }
      respond 404
    '';
    "*.preview.myparcelle.tyrode.dev".extraConfig = ''
      tls {
        on_demand
      }
      encode zstd gzip
      reverse_proxy 127.0.0.1:4300
    '';
  };
}
