{ lib, ... }:

let
  # One description of one fact: the addresses this machine answers on are
  # stated once, in `address.nix`, and both the uplink below and the name the
  # fleet reaches it by are derived from that file.
  machine = import ./address.nix;
in
{
  networking = {
    networkmanager.enable = lib.mkForce false;
    useDHCP = lib.mkForce false;
    useNetworkd = lib.mkForce true;
    wireless.enable = lib.mkForce false;
  };

  # clan-core's clanCore/networking.nix deliberately disables
  # systemd-networkd wait-online for managed machines; the static plan
  # below does not depend on it.
  #
  # The plan is written literally rather than generated from an intent file
  # because this machine has one uplink whose address, gateway and MAC never
  # change: a generator would be a second description of the same three facts,
  # and the value it produced could only be read by evaluating it. What
  # systemd-networkd receives is what a reviewer sees here.
  systemd.network = {
    links = lib.mkForce { };
    netdevs = lib.mkForce { };
    networks = lib.mkForce {
      "00-uplink" = {
        matchConfig.MACAddress = machine.mac;
        address = [
          "${machine.ipv4}/${toString machine.ipv4PrefixLength}"
          "${machine.ipv6}/${toString machine.ipv6PrefixLength}"
        ];
        networkConfig = {
          DHCP = "no";
          EmitLLDP = false;
          IPv6AcceptRA = false;
          LLDP = false;
          LLMNR = false;
          LinkLocalAddressing = "ipv6";
          MulticastDNS = false;
        };
        routes = [
          {
            Destination = "0.0.0.0/0";
            Gateway = machine.ipv4Gateway;
            GatewayOnLink = true;
          }
          {
            Destination = "::/0";
            Gateway = machine.ipv6Gateway;
            GatewayOnLink = true;
            IPv6Preference = "medium";
            Metric = 1024;
          }
        ];
      };
    };
  };
}
