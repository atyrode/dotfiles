# The parxel design-preview checkout owns its runtime (a Vite dev server with
# hot reload) and publishes it on loopback; the host keeps one stable HTTPS
# edge so ordinary preview edits never require an activation. The preview is
# static and data-free, separate from the myparcelle edge; no secret lives here.
# Caddy forwards the hot-reload WebSocket upgrade on the same host unaided.
_: {
  services.caddy.virtualHosts."parxel.tyrode.dev".extraConfig = ''
    encode zstd gzip
    reverse_proxy 127.0.0.1:4175
  '';
}
