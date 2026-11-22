# Runs the real modules/nixos/mac-tern-fleet.nix on a VM that plays dev-01: a
# real WireGuard `fleet` link to the Mac, to an existing fleet peer, and (once
# the service enrolls it) to a restricted Windows device. Keys are derived in
# the guests from fixed phrases and every address is a fixture; no deployed
# secret or vendor binary is involved. The Windows device is hostile on
# purpose: it widens its own AllowedIPs, routes everything into the tunnel and
# forges another peer's source, and must still reach only the Mac's UDP port.
{ pkgs }:
let
  inherit (pkgs) lib;
  port = 944;
  wgPort = 51820;
  prefix = "fd42:944:0:100";
  hubAddress = "${prefix}::1";
  host = {
    interface = "fleet";
    inherit port;
    address = "${prefix}::10";
    clientAddress = "${prefix}:0:ffff:0:2";
    clientWireGuardPublicKey = "DpTuVrLMUE4drMM0JOCro+n9HASc+iuz8FrpNsrcj3E=";
    clientPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMmn5xo5Mm9FhaLV2ZeTQnYYQmzPqxvXZNOxrw7+k9d/";
    serverPublicKey = "V2ZI68mzmbTpkyBnzbmpGo/qTi7XLASJSifxGvd56jE=";
    endpoint = "dev-01.fixture";
    endpointPort = wgPort;
  };
  peerAddress = "${prefix}::12";
  keyFile = "/var/lib/fleet-fixture.key";

  # Fixture keys: the sha256 of a phrase, so the Windows and hub public keys
  # above are fixed while no private key is stored in the repository.
  deriveKey = unit: phrase: {
    systemd.services.fleet-fixture-key = {
      wantedBy = [ unit ];
      before = [ unit ];
      path = [ pkgs.openssl ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        printf %s ${lib.escapeShellArg phrase} | openssl dgst -sha256 -binary | base64 >${keyFile}
      '';
    };
  };

  # Echo every datagram and accept every connection on the given ports, on
  # every address, logging "<proto> <port> <source>".
  listener = pkgs.writeText "mac-tern-listener.py" ''
    import ipaddress, selectors, socket, sys
    sel = selectors.DefaultSelector()
    log = open(sys.argv[1], "a", buffering=1)
    def bind(kind, port):
        s = socket.socket(socket.AF_INET6, kind)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("::", port))
        if kind == socket.SOCK_STREAM:
            s.listen(8)
        sel.register(s, selectors.EVENT_READ, (kind, port))
    for spec in sys.argv[2:]:
        proto, number = spec.split("/")
        bind(socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM, int(number))
    while True:
        for key, _ in sel.select():
            kind, port = key.data
            if kind == socket.SOCK_DGRAM:
                data, peer = key.fileobj.recvfrom(64)
                key.fileobj.sendto(b"ok", peer)
                name = "udp"
            else:
                conn, peer = key.fileobj.accept()
                conn.close()
                name = "tcp"
            log.write(f"{name} {port} {ipaddress.ip_address(peer[0])}\n")
  '';
  scripted = "wireguard-${host.interface}.service";
  listen = unit: ports: {
    systemd.services.fixture-listener.serviceConfig.ExecStart =
      "${pkgs.python3}/bin/python3 ${listener} /run/listener.log ${lib.concatStringsSep " " ports}";
    systemd.services.fixture-listener.wantedBy = [ "multi-user.target" ];
    systemd.services.fixture-listener.after = [ unit ];
  };

  # proto dest port [source]: "reply" for a UDP answer, "open" for a TCP
  # handshake, otherwise "silent".
  probe = pkgs.writeText "mac-tern-probe.py" ''
    import socket, sys
    proto, dest, port = sys.argv[1:4]
    source = sys.argv[4] if len(sys.argv) > 4 else "-"
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM if proto == "udp" else socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        if source != "-":
            s.bind((source, 0))
        if proto == "udp":
            s.sendto(b"hi", (dest, int(port)))
            s.recvfrom(64)
            print("reply")
        else:
            s.connect((dest, int(port)))
            print("open")
    except (socket.timeout, OSError):
        print("silent")
  '';

  endpoint = {
    networking.firewall.enable = false;
    environment.systemPackages = [
      pkgs.python3
      pkgs.wireguard-tools
    ];
  };
  node =
    {
      phrase ? null,
      ips,
      ports,
    }:
    {
      imports = [
        endpoint
        (listen scripted ports)
      ]
      ++ lib.optional (phrase != null) (deriveKey scripted phrase);
      networking.wireguard.interfaces.${host.interface} = {
        inherit ips;
        privateKeyFile = keyFile;
        generatePrivateKeyFile = phrase == null;
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "mac-tern-fleet";
  requiredFeatures.kvm = false;
  nodes = {
    hub =
      { config, ... }:
      {
        imports = [
          (import ../../modules/nixos/mac-tern-fleet.nix {
            inherit config lib pkgs;
            macTernHostFixture = host;
          })
          (deriveKey "systemd-networkd.service" "Mac fleet hub VM server fixture")
          # The hub's own services, open to the whole fleet interface as
          # dev-01's are: the module, not the firewall, must keep the
          # restricted device away from them.
          (listen "sys-subsystem-net-devices-${host.interface}.device" [
            "tcp/22"
            "tcp/8080"
            "udp/${toString port}"
          ])
        ];
        # As on dev-01, systemd-networkd owns the overlay device: the NixOS
        # WireGuard module renders a netdev, not a `wireguard-fleet` unit. The
        # Mac, Windows and the existing peer stay scripted guests.
        networking.useNetworkd = true;
        networking.firewall = {
          enable = true;
          backend = "iptables";
          # dev-01's public SSH, open on every interface.
          allowedTCPPorts = [ 22 ];
          allowedUDPPorts = [ wgPort ];
          interfaces.${host.interface} = {
            allowedTCPPorts = [ 8080 ];
            allowedUDPPorts = [ port ];
          };
        };
        networking.wireguard.interfaces.${host.interface} = {
          ips = [ "${hubAddress}/56" ];
          listenPort = wgPort;
          privateKeyFile = keyFile;
        };
        # Clan's controller forwards between its peers on dev-01; so does this hub.
        boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
        environment.systemPackages = [
          pkgs.python3
          pkgs.wireguard-tools
        ];
      };
    mac = node {
      phrase = null;
      ips = [ "${host.address}/56" ];
      ports = [
        "udp/${toString port}"
        "udp/945"
        "tcp/${toString port}"
        "tcp/22"
      ];
    };
    windows = {
      imports = [
        endpoint
        (deriveKey scripted "Mac fleet VM windows fixture")
      ];
      networking.wireguard.interfaces.${host.interface} = {
        ips = [ "${host.clientAddress}/128" ];
        privateKeyFile = keyFile;
      };
    };
  };
  testScript =
    { nodes, ... }:
    ''
      import ipaddress

      IFACE = "${host.interface}"
      HUB = "${hubAddress}"
      MAC = "${host.address}"
      WIN = "${host.clientAddress}"
      PEER = "${peerAddress}"
      HUB4 = "${nodes.hub.networking.primaryIPAddress}"
      HUB6 = "${nodes.hub.networking.primaryIPv6Address}"
      WIN_KEY = "${host.clientWireGuardPublicKey}"
      probe = "python3 ${probe}"

      def verdict(machine, *args):
          return machine.succeed(f"{probe} {' '.join(args)}").strip()

      def heard(machine, path="/run/listener.log"):
          return [line.split() for line in machine.succeed(f"cat {path} || true").splitlines()]

      # The existing fleet peer is a second WireGuard device in a network
      # namespace of the Mac's guest: its own key, address and sockets, one
      # guest fewer. The device is created in the guest's namespace, so its
      # UDP socket reaches the hub over the plain network.
      def in_peer(machine_cmd):
          return f"ip netns exec peer {machine_cmd}"

      def peer_verdict(*args):
          return mac.succeed(in_peer(f"{probe} {' '.join(args)}")).strip()

      # No start_all(): the guests boot one after another as the waits below
      # reach them, so only one initrd mounts its store at a time.
      for m in (mac, windows):
          m.wait_for_unit(f"wireguard-{IFACE}.service")
      hub.wait_for_unit("systemd-networkd.service")
      hub.wait_for_unit(f"sys-subsystem-net-devices-{IFACE}.device")
      for m in (hub, mac):
          m.wait_for_unit("fixture-listener.service")
      mac.succeed(
          "ip netns add peer",
          "ip link add peerwg type wireguard",
          "ip link set peerwg netns peer",
          in_peer("ip link set lo up"),
          in_peer("sh -c 'umask 077; wg genkey >/run/peer.key'"),
          in_peer("wg set peerwg private-key /run/peer.key"),
          in_peer(f"ip -6 addr add {PEER}/56 dev peerwg"),
          in_peer("ip link set peerwg up"),
          "systemd-run --unit=peer-listener "
          + in_peer(
              "${pkgs.python3}/bin/python3 ${listener} /run/peer-listener.log udp/${toString port} tcp/22"
          ),
      )
      assert hub.succeed(f"wg show {IFACE} public-key").strip() == "${host.serverPublicKey}"
      assert windows.succeed(f"wg show {IFACE} public-key").strip() == WIN_KEY

      keys = {m.name: m.succeed(f"wg show {IFACE} public-key").strip() for m in (hub, mac)}
      keys["peer"] = mac.succeed(in_peer("wg show peerwg public-key")).strip()
      hub_key = keys["hub"]
      assert hub_key == "${host.serverPublicKey}"

      # The existing fleet: the hub reaches each peer and each peer holds the whole
      # overlay through the hub, as clan lays it out.
      def fleet_peers():
          setup = f"peer {hub_key} allowed-ips ${prefix}::/56 endpoint {HUB4}:${toString wgPort} persistent-keepalive 1"
          mac.succeed(f"wg set {IFACE} {setup}")
          mac.succeed(in_peer(f"wg set peerwg {setup}"))
          for name, addr in (("mac", MAC), ("peer", PEER)):
              hub.succeed(f"wg set {IFACE} peer {keys[name]} allowed-ips {addr}/128")
          mac.wait_until_succeeds(f"ping -6 -c1 -W2 {HUB}")
          mac.wait_until_succeeds(in_peer(f"ping -6 -c1 -W2 {HUB}"))

      fleet_peers()

      # The restricted device: its own tunnel carries only the Mac's address.
      windows.succeed(
          f"wg set {IFACE} peer {hub_key} allowed-ips {MAC}/128 "
          f"endpoint {HUB4}:${toString wgPort} persistent-keepalive 1"
      )
      windows.succeed(f"ip -6 route replace {MAC}/128 dev {IFACE}")

      # The service enrolls the device with exactly its own address.
      hub.wait_for_unit("mac-tern-fleet-peer.service")

      def enrolled():
          listed = hub.succeed(f"wg show {IFACE} allowed-ips | grep {WIN_KEY}").split()[1:]
          assert [ipaddress.ip_interface(a) for a in listed] == [ipaddress.ip_interface(WIN + "/128")], listed

      def hostile():
          # The device overrides everything it controls: its AllowedIPs widen
          # to the whole address space and every route goes into the tunnel.
          windows.succeed(f"wg set {IFACE} peer {hub_key} allowed-ips ::/0")
          windows.succeed(f"ip -6 route replace ::/0 dev {IFACE}")

      def matrix():
          windows.wait_until_succeeds(f"{probe} udp {MAC} ${toString port} {WIN} | grep -x reply")
          # Nothing else on the Mac, from the enrolled address ...
          for proto, dest, p in (
              ("udp", MAC, "945"),
              ("tcp", MAC, "${toString port}"),
              ("tcp", MAC, "22"),
              ("udp", MAC, "51820"),
              # ... nothing on the hub itself, on any of its addresses ...
              ("tcp", HUB, "22"),
              ("tcp", HUB, "8080"),
              ("udp", HUB, "${toString port}"),
              ("udp", HUB, "${toString wgPort}"),
              ("tcp", HUB6, "22"),
              ("udp", HUB6, "${toString port}"),
              # ... and nothing on another fleet peer.
              ("udp", PEER, "${toString port}"),
              ("tcp", PEER, "22"),
          ):
              assert verdict(windows, proto, dest, p, WIN) == "silent", (proto, dest, p)
          # A forged source gets no reply: the hub tunnel drops it unless it is Windows'.
          for forged in (PEER, HUB):
              windows.succeed(f"ip -6 addr add {forged}/128 dev {IFACE} nodad")
              assert verdict(windows, "udp", MAC, "${toString port}", forged) == "silent", forged
              windows.succeed(f"ip -6 addr del {forged}/128 dev {IFACE}")
          seen = {(p, port_, src) for p, port_, src in heard(mac)}
          assert seen == {("udp", "${toString port}", str(ipaddress.ip_address(WIN)))}, seen
          assert all(src != str(ipaddress.ip_address(WIN)) for _, _, src in heard(hub)), heard(hub)
          assert all(src != str(ipaddress.ip_address(WIN)) for _, _, src in heard(mac, "/run/peer-listener.log")), heard(mac, "/run/peer-listener.log")

      def existing_fleet():
          # The existing peer still reaches the hub and its own overlay.
          assert peer_verdict("tcp", HUB, "22") == "open"
          assert peer_verdict("tcp", HUB, "8080") == "open"
          assert peer_verdict("udp", HUB, "${toString port}") == "reply"
          mac.succeed(in_peer(f"ping -6 -c1 -W2 {HUB}"))
          mac.succeed(f"ping -6 -c1 -W2 {HUB}")

      enrolled()
      hostile()
      matrix()
      existing_fleet()

      # Restarting the service re-enrolls the device and keeps the guard.
      hub.succeed("systemctl restart mac-tern-fleet-peer.service")
      enrolled()
      matrix()
      existing_fleet()

      # Stop removes the peer first, then the guard: the device reaches nothing.
      hub.succeed("systemctl stop mac-tern-fleet-peer.service")
      assert WIN_KEY not in hub.succeed(f"wg show {IFACE} peers")
      hub.fail("ip6tables -w -t raw -S mac-tern-in")
      hub.fail("ip6tables -w -t raw -S mac-tern-out")
      windows.fail(f"{probe} udp {MAC} ${toString port} {WIN} | grep -x reply")
      existing_fleet()

      # Start restores the guard and the peer.
      hub.succeed("systemctl start mac-tern-fleet-peer.service")
      enrolled()
      matrix()
      existing_fleet()

      # Losing the overlay device drops every runtime peer and the bound unit
      # with it. When networkd creates the device again the unit must come
      # back, enroll Windows again and keep the guard once the fleet is
      # re-peered.
      hub.succeed(f"ip link del {IFACE}")
      hub.wait_until_succeeds(f"! ip link show {IFACE}")
      hub.succeed("systemctl restart systemd-networkd.service")
      hub.wait_until_succeeds(f"ip link show {IFACE}")
      hub.wait_for_unit("mac-tern-fleet-peer.service")
      hub.succeed("ip6tables -w -t raw -S mac-tern-in")
      fleet_peers()
      enrolled()
      matrix()
      existing_fleet()
    '';
}
