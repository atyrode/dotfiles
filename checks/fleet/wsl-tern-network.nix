# Runs the real modules/nixos/wsl-tern-network.nix (firewall rule and raw-table
# guard) on a VM that has a real WireGuard `fleet` link to two peers. Every key
# is generated in the guests and every address is a fixture; no vendor binary
# or deployed secret is involved.
{ pkgs }:
let
  inherit (pkgs) lib;
  port = 944;
  host = {
    interface = "fleet";
    inherit port;
    address = "fd42:944:0:100::10";
    clientAddress = "fd42:944:0:100::11";
    clientPublicKey = null;
    hostname = "wsl.fleet";
  };
  otherAddress = "fd42:944:0:100::12";
  wgPort = 51820;
  keyFile = "/var/lib/fleet-fixture.key";

  # Dual-stack wildcard socket: IPv4 reaches it only if the guard lets it.
  listener = pkgs.writeText "tern-udp-fixture.py" ''
    import ipaddress, socket
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    s.bind(("::", ${toString port}))
    log = open("/run/tern-udp-fixture.log", "a", buffering=1)
    while True:
        data, peer = s.recvfrom(64)
        log.write(str(ipaddress.ip_address(peer[0])) + "\n")
        s.sendto(b"ok", peer)
  '';
  probe = pkgs.writeText "tern-udp-probe.py" ''
    import socket, sys
    dest, family, source = sys.argv[1:4]
    s = socket.socket(socket.AF_INET6 if family == "6" else socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    if source != "-":
        s.bind((source, 0))
    s.sendto(b"hi", (dest, ${toString port}))
    try:
        s.recvfrom(64)
    except socket.timeout:
        print("silent")
    else:
        print("reply")
  '';

  client = address: {
    networking.firewall.enable = false;
    networking.wireguard.interfaces.${host.interface} = {
      ips = [ "${address}/56" ];
      privateKeyFile = keyFile;
      generatePrivateKeyFile = true;
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.wireguard-tools
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "wsl-tern-network";
  requiredFeatures.kvm = false;
  nodes = {
    wsl =
      { config, ... }:
      {
        imports = [
          (import ../../modules/nixos/wsl-tern-network.nix {
            inherit config lib;
            wslTernHostFixture = host;
          })
        ];
        networking.firewall = {
          enable = true;
          backend = "iptables";
          allowedUDPPorts = [ wgPort ];
        };
        # Mirror NixOS-WSL: firewall logically enabled (module rules and
        # assertions hold) but its systemd unit is masked and never runs.
        systemd.services.firewall.enable = false;
        networking.wireguard.interfaces.${host.interface} = {
          ips = [ "${host.address}/56" ];
          listenPort = wgPort;
          privateKeyFile = keyFile;
          generatePrivateKeyFile = true;
        };
        systemd.services.tern-udp-fixture = {
          wantedBy = [ "multi-user.target" ];
          bindsTo = [ "wsl-tern-ingress.service" ];
          after = [ "wsl-tern-ingress.service" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${listener}";
        };
        environment.systemPackages = [ pkgs.wireguard-tools ];
        boot.initrd.kernelModules = [ "virtio_console" ];
      };
    mac = client host.clientAddress;
    other = client otherAddress;
  };
  testScript =
    { nodes, ... }:
    ''
      import ipaddress

      ADDRESS = "${host.address}"
      MAC = "${host.clientAddress}"
      WSL4 = "${nodes.wsl.networking.primaryIPAddress}"
      WSL6 = "${nodes.wsl.networking.primaryIPv6Address}"
      probe = "python3 ${probe}"

      start_all()
      for m in (wsl, mac, other):
          m.wait_for_unit("wireguard-${host.interface}.service")
      wsl.wait_for_unit("tern-udp-fixture.service")

      keys = {m.name: m.succeed("wg show ${host.interface} public-key").strip() for m in (wsl, mac, other)}
      for m, addr in ((mac, MAC), (other, "${otherAddress}")):
          m.succeed(
              f"wg set ${host.interface} peer {keys['wsl']} allowed-ips {ADDRESS}/128 "
              f"endpoint {WSL4}:${toString wgPort} persistent-keepalive 1"
          )
          wsl.succeed(f"wg set ${host.interface} peer {keys[m.name]} allowed-ips {addr}/128")
      for m in (mac, other):
          m.wait_until_succeeds(f"ping -6 -c1 -W2 {ADDRESS}")

      # Off-interface source: forge the Mac's address on the plain network.
      other.succeed(f"ip -6 addr add {MAC}/128 dev eth1 nodad")
      other.succeed(f"ip -6 route add {ADDRESS}/128 via {WSL6} dev eth1")

      def matrix():
          mac.wait_until_succeeds(f"{probe} {ADDRESS} 6 - | grep -x reply")
          for cmd in (
              f"{probe} {ADDRESS} 6 -",  # same subnet, other enrolled peer
              f"{probe} {ADDRESS} 6 {MAC}",  # Mac's address, off the fleet interface
              f"{probe} {WSL4} 4 -",  # IPv4 on the wildcard-bound socket
          ):
              assert other.succeed(cmd).strip() == "silent", cmd
          # The guest also must not see the Mac's own IPv4 side door.
          assert mac.succeed(f"{probe} {WSL4} 4 -").strip() == "silent"
          seen = set(wsl.succeed("cat /run/tern-udp-fixture.log").split())
          assert seen == {str(ipaddress.ip_address(MAC))}, seen

      matrix()

      # The WSL shape: firewall.service is masked and never ran; the guard and
      # fixture are up without it.
      def assert_firewall_absent():
          assert wsl.succeed("systemctl is-enabled firewall.service || true").strip() == "masked"
          assert wsl.succeed("systemctl is-active firewall.service || true").strip() == "inactive"

      assert_firewall_absent()
      wsl.fail("systemctl start firewall.service")
      wsl.succeed("systemctl is-active wsl-tern-ingress.service tern-udp-fixture.service")
      wsl.succeed("ip6tables -w -t raw -S wsl-tern")
      wsl.succeed("iptables -w -t raw -S wsl-tern")
      matrix()

      # Guard restart: the bound listener comes back with it.
      wsl.succeed("systemctl restart wsl-tern-ingress.service")
      wsl.succeed("systemctl start tern-udp-fixture.service")
      assert_firewall_absent()
      matrix()

      # Guard stop: the bound listener shuts down and the chains go away;
      # start recovers both, still without the global firewall.
      wsl.succeed("systemctl stop wsl-tern-ingress.service")
      wsl.wait_until_succeeds("systemctl is-active tern-udp-fixture.service | grep -x inactive")
      wsl.fail("ip6tables -w -t raw -S wsl-tern")
      wsl.fail("iptables -w -t raw -S wsl-tern")
      wsl.succeed("systemctl start wsl-tern-ingress.service tern-udp-fixture.service")
      assert_firewall_absent()
      matrix()
    '';
}
