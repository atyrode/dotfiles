# The house-studio checkout owns its runtime (the Next.js studio in Docker
# Compose, its data directory outside the checkout) and publishes it on
# loopback; the host keeps one stable HTTPS edge so ordinary studio edits never
# require an activation. The studio handles its own keys; no secret lives here.
_: {
  services.caddy.virtualHosts."studio.tyrode.dev".extraConfig = ''
    reverse_proxy 127.0.0.1:8095
  '';
}
