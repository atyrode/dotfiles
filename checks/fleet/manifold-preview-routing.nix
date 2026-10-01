{ pkgs, previewVhost }:
let
  # Adapt the deployed vhost itself. The fixture changes only listener/TLS transport
  # and upstream ports, then proves HTTP and WebSocket routing through real Caddy.
  caddyfile = pkgs.writeText "manifold-preview-routing.Caddyfile" ''
    preview.manifold.tyrode.dev {
      ${previewVhost}
    }
  '';
in
pkgs.runCommand "check-manifold-preview-routing"
  {
    nativeBuildInputs = [
      pkgs.caddy
      pkgs.python3
    ];
  }
  ''
    python3 ${./manifold-preview-routing.py} ${caddyfile}
    mkdir "$out"
  ''
