{ pkgs, caddy }:
let
  # The deployed global gate and dispatcher site, as dev-01 declares them.
  # Only listener and upstream ports change in the fixture.
  dispatcher = caddy.virtualHosts."http://127.0.0.1:7899";
  caddyfile = pkgs.writeText "caddy-on-demand-ask.Caddyfile" ''
    {
      ${caddy.globalConfig}
    }
    http://127.0.0.1:7899 {
      bind ${builtins.concatStringsSep " " dispatcher.listenAddresses}
      ${dispatcher.extraConfig}
    }
  '';
  zones = pkgs.writeText "caddy-on-demand-ask-zones.json" (builtins.toJSON caddy.zones);
in
pkgs.runCommand "check-caddy-on-demand-ask"
  {
    nativeBuildInputs = [
      pkgs.caddy
      pkgs.python3
    ];
  }
  ''
    python3 ${./caddy-on-demand-ask.py} ${caddyfile} "$(cat ${zones})"
    mkdir "$out"
  ''
