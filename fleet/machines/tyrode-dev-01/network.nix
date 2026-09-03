{ lib, ... }:

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
      "00-tyrode-uplink" = {
        matchConfig.MACAddress = "e6:fa:af:f1:7b:6a";
        address = [
          "152.53.112.19/22"
          "2a0a:4cc0:80:41e4:e4fa:afff:fef1:7b6a/64"
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
            Gateway = "152.53.112.1";
            GatewayOnLink = true;
          }
          {
            Destination = "::/0";
            Gateway = "fe80::1";
            GatewayOnLink = true;
            IPv6Preference = "medium";
            Metric = 1024;
          }
        ];
      };
    };
  };
}
