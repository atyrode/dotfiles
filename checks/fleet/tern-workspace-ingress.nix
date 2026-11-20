{ pkgs, config }:
let
  inherit (pkgs) lib;
  workspace = import ../../fleet/tern-workspace.nix;
  inherit (config.systemd.services) tern-workspace-ingress tern-workspace-caddy;
  ingress = pkgs.writeShellScript "tern-workspace-ingress" tern-workspace-ingress.script;
  caddyStart = tern-workspace-caddy.serviceConfig.ExecStart;
  # Keep the generated Caddyfile in the closure after extracting its argument.
  caddyfile = builtins.appendContext (builtins.elemAt (lib.splitString " " caddyStart) 3) (
    builtins.getContext caddyStart
  );
in
pkgs.writeShellApplication {
  name = "check-tern-workspace-ingress";
  runtimeInputs =
    with pkgs;
    [ bash caddy coreutils curl gnused iproute2 openssl python3 util-linux wireguard-tools ]
    ++ tern-workspace-ingress.path;
  text = ''
    exec unshare -Urn bash ${./tern-workspace-ingress.sh} ${lib.escapeShellArgs [
      ingress
      caddyfile
      workspace.hostname
      workspace.interface
      workspace.serverAddress
      workspace.peers.macbook.address
      (toString workspace.port)
      (toString workspace.webPort)
      (toString workspace.proxyPort)
    ]}
  '';
}
