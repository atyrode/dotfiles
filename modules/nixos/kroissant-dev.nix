# The kroissant checkout owns its development stack (WordPress + MySQL in
# Docker Compose, live reload) and publishes it on loopback; the host keeps
# one stable HTTPS edge so ordinary site edits never require an activation.
# Production stays on its own hosting; this edge only ever serves development.
_: {
  services.caddy.virtualHosts."kroissant.tyrode.dev".extraConfig = ''
    reverse_proxy 127.0.0.1:8094
  '';
}
