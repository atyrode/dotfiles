# Hub side of the Windows -> Mac private Tern path, on dev-01. The Windows
# workstation is a restricted external peer of the existing `fleet` overlay,
# not a clan machine, and the hub carries its datagrams to exactly one
# destination: the Mac's Tern QUIC port.
#
# Enforcement is here, never in a client's AllowedIPs:
#   - `mac-tern-in` (ip6tables raw PREROUTING) passes only
#     client -> Mac udp/<port> and Mac udp/<port> -> client, both on the
#     overlay interface, and drops every other packet with the client as
#     source or destination, whatever interface it arrives on. This covers
#     traffic to the hub itself (SSH, anything) and any forwarding.
#   - `mac-tern-out` (raw OUTPUT) stops the hub originating to the client.
#   - No firewall port is opened; the overlay's UDP port is already clan's.
#
# The peer is runtime state (`wg set`), so the guard is installed before it
# exists and removed only after it is proved gone. Any failed read, removal
# or verification leaves the guard in place. The unit is bound to the overlay
# device and, under networkd, follows systemd-networkd: generated WireGuard
# netdevs replace their peers when networkd applies them, so a networkd
# restart stops this unit and re-enrols the peer afterwards. A bare
# `networkctl reload`/`reconfigure` does not restart units and can drop the
# peer silently (fail closed: the guard stays); restart this unit to recover.
{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  host = args.macTernHostFixture or (import ../../fleet/mac-tern-host.nix);
  inherit (host)
    address
    clientAddress
    clientWireGuardPublicKey
    interface
    port
    ;
  fw = config.networking.firewall;
  overlay = config.networking.wireguard.interfaces.${interface} or null;
  inChain = "mac-tern-in";
  outChain = "mac-tern-out";
  service = "mac-tern-fleet-peer";
  device = "sys-subsystem-net-devices-${interface}.device";
  wgUnit = "wireguard-${interface}.service";
  hasWgUnit = config.systemd.services ? "wireguard-${interface}";
  networkd = config.networking.useNetworkd;
  networkdUnits = lib.optional networkd "systemd-networkd.service";
  guardUnits = [ device ] ++ lib.optional hasWgUnit wgUnit ++ networkdUnits;
  wg = "${pkgs.wireguard-tools}/bin/wg";
  waitOnline = "${config.systemd.package}/lib/systemd/systemd-networkd-wait-online";

  # The one place a peer leaves the interface. Absence is proved only by the
  # device not existing or a successful read lacking the key; every other
  # outcome is a failure and callers keep the guard.
  helpers = ''
    device_absent() { [ ! -e /sys/class/net/${interface} ]; }
    peer_listed() {
      local peers
      peers=$(${wg} show ${interface} peers) || return 2
      if printf '%s\n' "$peers" | grep -qxF '${clientWireGuardPublicKey}'; then return 0; fi
      return 1
    }
    detach_peer() {
      local rc=0
      device_absent && return 0
      peer_listed || rc=$?
      [ "$rc" -eq 1 ] && return 0
      [ "$rc" -eq 0 ] || return 1
      ${wg} set ${interface} peer '${clientWireGuardPublicKey}' remove || return 1
      rc=0
      peer_listed || rc=$?
      [ "$rc" -eq 1 ]
    }
  '';

  checkPeers = pkgs.writeText "mac-tern-check-peers.py" ''
    import ipaddress, subprocess, sys
    iface, key, client = sys.argv[1], sys.argv[2], ipaddress.ip_address(sys.argv[3])
    out = subprocess.run(["${wg}", "show", iface, "allowed-ips"], check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        peer, _, ranges = line.partition("\t")
        if peer == key:
            continue
        for r in ranges.split():
            if r == "(none)":
                continue
            net = ipaddress.ip_network(r, strict=False)
            if net.version == 6 and net.prefixlen >= 96 and client in net:
                sys.exit("another peer already owns " + r)
  '';
in
{
  assertions = [
    {
      assertion = fw.enable && fw.backend == "iptables";
      message = "Mac Tern admission requires the iptables firewall backend.";
    }
    {
      assertion = overlay != null;
      message = "The fleet overlay `${interface}` must exist on this host.";
    }
    {
      assertion = !(lib.any (peer: peer.publicKey == clientWireGuardPublicKey) overlay.peers);
      message = "The Windows peer key is already a declared fleet peer.";
    }
  ];

  systemd.services.${service} = {
    # A changed generated netdev replaces its peers when networkd applies
    # it, so re-enrol whenever the unit text this host generates changes.
    restartTriggers = lib.optionals networkd (
      map (name: config.systemd.network.units.${name}.text) [
        "40-${interface}.netdev"
        "40-${interface}.network"
      ]
    );
    description = "Restricted Windows peer on the fleet overlay for the Mac's Tern host";
    # Pulled in by networkd starting and by the device appearing, so a
    # recreated device or restarted networkd re-enrols even from inactive.
    wantedBy = [ "multi-user.target" ] ++ networkdUnits ++ [ device ];
    bindsTo = [ device ] ++ lib.optional hasWgUnit wgUnit;
    partOf = guardUnits;
    after = guardUnits;
    path = [
      fw.package
      pkgs.iproute2
      pkgs.python3
      pkgs.wireguard-tools
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${helpers}
      ensure_chain() {
        ip6tables -w -t raw -S "$1" >/dev/null 2>&1 || ip6tables -w -t raw -N "$1"
      }
      ensure_jump() {
        ip6tables -w -t raw -C "$1" -j "$2" 2>/dev/null || ip6tables -w -t raw -I "$1" 1 -j "$2"
      }

      # A stale peer must be gone before the chains are rebuilt in place.
      detach_peer
      ensure_chain ${inChain}
      ensure_chain ${outChain}
      ip6tables -w -t raw -F ${outChain}
      ip6tables -w -t raw -A ${outChain} -d ${clientAddress}/128 -j DROP
      ip6tables -w -t raw -F ${inChain}
      ip6tables -w -t raw -A ${inChain} -i ${interface} -s ${clientAddress}/128 -d ${address}/128 -p udp --dport ${toString port} -j RETURN
      ip6tables -w -t raw -A ${inChain} -i ${interface} -s ${address}/128 -d ${clientAddress}/128 -p udp --sport ${toString port} -j RETURN
      ip6tables -w -t raw -A ${inChain} -s ${clientAddress}/128 -j DROP
      ip6tables -w -t raw -A ${inChain} -d ${clientAddress}/128 -j DROP
      ensure_jump PREROUTING ${inChain}
      ensure_jump OUTPUT ${outChain}
      # From here a failure detaches the peer; the guard stays regardless.
      trap 'rc=$?; detach_peer || rc=1; exit $rc' EXIT

      ${lib.optionalString networkd "${waitOnline} --interface=${interface} --timeout=60"}
      [ -e /sys/class/net/${interface} ]
      ${wg} show ${interface} public-key | grep -qxF '${host.serverPublicKey}'
      python3 ${checkPeers} ${interface} '${clientWireGuardPublicKey}' ${clientAddress}
      # The overlay's own prefix route must already carry the client.
      route=$(ip -6 route get ${clientAddress})
      case "$route" in
        *" dev ${interface} "*) ;;
        *) echo "no ${interface} route to ${clientAddress}: $route" >&2; exit 1 ;;
      esac
      ${wg} set ${interface} peer '${clientWireGuardPublicKey}' allowed-ips ${clientAddress}/128
      trap - EXIT
    '';
    postStop = ''
      set -u
      ${helpers}
      # Only a proved-absent peer lets the guard go; otherwise it stays.
      detach_peer || { echo "peer not proved detached; guard kept" >&2; exit 1; }
      for pair in "PREROUTING ${inChain}" "OUTPUT ${outChain}"; do
        set -- $pair
        while ip6tables -w -t raw -D "$1" -j "$2" 2>/dev/null; do :; done
        if ip6tables -w -t raw -S "$2" >/dev/null 2>&1; then
          ip6tables -w -t raw -F "$2"
          ip6tables -w -t raw -X "$2"
        fi
      done
    '';
  };
}
