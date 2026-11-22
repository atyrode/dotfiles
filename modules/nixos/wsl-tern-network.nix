# Network admission for the private Tern host on WSL: one UDP (QUIC) port, answered
# on the fleet overlay for the Mac's overlay address only. Nothing else is
# opened and the fleet's SSH and tunnel policy is untouched.
#
# Two layers, because the NixOS firewall reloads non-atomically and stops
# without a default policy:
#   - the firewall's own `nixos-fw` chain accepts exactly the Mac;
#   - `wsl-tern-ingress` owns raw-table guards that drop every other packet
#     addressed to this host on that port, on any interface and either IP
#     family, including while the firewall reloads or is stopped.
# The listener must start after, and be bound to, `wsl-tern-ingress.service`.
{
  config,
  lib,
  ...
}@args:
let
  host = args.wslTernHostFixture or (import ../../fleet/wsl-tern-host.nix);
  inherit (host)
    address
    clientAddress
    interface
    port
    ;
  fw = config.networking.firewall;
  guardChain = "wsl-tern";
  service = "wsl-tern-ingress";
  allowRule = "-i ${interface} -s ${clientAddress}/128 -d ${address}/128 -p udp --dport ${toString port}";
  covers = range: range.from <= port && port <= range.to;
  opensPort =
    scope: builtins.elem port scope.allowedUDPPorts || builtins.any covers scope.allowedUDPPortRanges;
  overlay = config.networking.wireguard.interfaces.${interface} or null;
in
{
  assertions = [
    {
      assertion = fw.enable && fw.backend == "iptables";
      message = "WSL Tern admission requires the iptables firewall backend.";
    }
    {
      assertion =
        !(opensPort fw)
        && !(lib.any opensPort (lib.attrValues fw.interfaces))
        && !(builtins.elem interface fw.trustedInterfaces);
      message = "UDP port ${toString port} must be opened only by wsl-tern-network.nix.";
    }
    {
      assertion = overlay != null && builtins.elem "${address}/56" overlay.ips;
      message = "The fleet overlay must carry ${address}/56 on ${interface}.";
    }
  ];

  networking.firewall.extraCommands = ''
    ip6tables -A nixos-fw ${allowRule} -j nixos-fw-accept
  '';

  systemd.services.${service} = {
    description = "Drop Tern host traffic except from the Mac over the fleet overlay";
    wantedBy = [ "multi-user.target" ];
    bindsTo = [ "firewall.service" ];
    partOf = [ "firewall.service" ];
    after = [ "firewall.service" ];
    path = [ fw.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      cleanup() {
        for tool in iptables ip6tables; do
          if "$tool" -w -t raw -S ${guardChain} >/dev/null 2>&1; then
            while "$tool" -w -t raw -D PREROUTING -j ${guardChain} 2>/dev/null; do :; done
            "$tool" -w -t raw -F ${guardChain}
            "$tool" -w -t raw -X ${guardChain}
          fi
        done
      }
      cleanup
      trap 'cleanup' ERR

      # Anything else for this port on a local address is dropped before
      # routing or the firewall sees it; loopback stays for the host itself.
      drop() {
        "$1" -w -t raw -A ${guardChain} -p udp --dport ${toString port} \
          -m addrtype --dst-type LOCAL ! -i lo -j DROP
      }

      ip6tables -w -t raw -N ${guardChain}
      ip6tables -w -t raw -A ${guardChain} ${allowRule} -j RETURN
      drop ip6tables
      iptables -w -t raw -N ${guardChain}
      drop iptables
      for tool in iptables ip6tables; do
        "$tool" -w -t raw -I PREROUTING -j ${guardChain}
      done
    '';
    postStop = ''
      for tool in iptables ip6tables; do
        if "$tool" -w -t raw -S ${guardChain} >/dev/null 2>&1; then
          while "$tool" -w -t raw -D PREROUTING -j ${guardChain} 2>/dev/null; do :; done
          "$tool" -w -t raw -F ${guardChain}
          "$tool" -w -t raw -X ${guardChain}
        fi
      done
    '';
  };
}
