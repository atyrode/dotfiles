# The games checkout owns its runtime and path routing. The host keeps one
# stable HTTPS edge so ordinary game edits never require a machine activation.
_: {
  services.caddy.virtualHosts."games.tyrode.dev".extraConfig = ''
    reverse_proxy 127.0.0.1:8093
  '';
}
