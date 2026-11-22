{ config, lib, ... }:

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

  # nixos-facter would otherwise add a DHCP-by-default networking.interfaces
  # entry (a second 40-ens3.network) for the detected NIC; the uplink below
  # is the only plan for it.
  facter.detected.dhcp.enable = false;

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
    networks = {
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

  # The Clan fleet WireGuard interface rides NixOS's networkd backend
  # (`networking.wireguard.useNetworkd` follows `networking.useNetworkd`),
  # which emits `40-<interface>.netdev` and `40-<interface>.network` and hands
  # the private key to systemd-networkd as a credential. The scripted backend
  # would drop that credential, so netdevs and networks are not forced empty.
  # This admits exactly the uplink and those generated files; anything else
  # fails evaluation instead of being silently discarded.
  assertions =
    let
      inherit (config.systemd.network) netdevs networks;
      wireguard = builtins.attrNames config.networking.wireguard.interfaces;
      generated = map (name: "40-${name}") wireguard;
    in
    [
      {
        assertion =
          builtins.attrNames netdevs == generated
          && builtins.attrNames networks == [ "00-uplink" ] ++ generated
          && networks."00-uplink".matchConfig == { MACAddress = machine.mac; }
          && lib.all (
            name:
            netdevs."40-${name}".netdevConfig == {
              Kind = "wireguard";
              Name = name;
            }
            && networks."40-${name}".matchConfig == { Name = name; }
          ) wireguard;
        message = "dev-01 systemd-networkd admits only 00-uplink and the WireGuard netdev and network of networking.wireguard.interfaces.";
      }
    ];
}
