{ pkgs }:
let
  inherit (pkgs) lib;
  liveTopology = import ../../fleet/tern-workspace.nix;
  # The corresponding private files are derived inside the guest, never
  # provisioned from the fleet. Only the Mac-shaped fixture peer is enrolled.
  workspace = liveTopology // {
    serverPublicKey = "kPcQmX1l3oIKbhXN/8h4pky+9fs++kEaF20k/IqevyU=";
    peers = {
      macbook = liveTopology.peers.macbook // {
        publicKey = "sGz/CCMqGffKXmAilP6rcOSQmfwtaE20xwXUG/w4Gh0=";
      };
      windows = liveTopology.peers.windows // {
        publicKey = null;
      };
    };
  };
  inherit (workspace) hostname interface;
  fixture = "/run/tern-ingress-fixture";
  privateKey = "${fixture}/server.key";
  dnsToken = "/run/secrets/vars/tern-workspace-dns/api-token";
  certDir = "/var/lib/acme/${hostname}";
  wireguardService = "wireguard-${interface}.service";
  probe = pkgs.writeShellApplication {
    name = "check-tern-workspace-ingress";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      iproute2
      python3
      util-linux
      wireguard-tools
    ];
    text = ''
      exec bash ${./tern-workspace-ingress.sh} ${
        lib.escapeShellArgs [
          fixture
          hostname
          interface
          workspace.serverAddress
          workspace.peers.macbook.address
          workspace.peers.windows.address
          (toString workspace.port)
          (toString workspace.webPort)
          (toString workspace.proxyPort)
          workspace.serverPublicKey
        ]
      }
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "tern-workspace-ingress";
  # Hosted Nix builders can run QEMU with software emulation and need no user namespaces.
  requiredFeatures.kvm = false;
  nodes.machine = {
    imports = [
      (
        {
          config,
          lib,
          pkgs,
          ...
        }:
        import ../../modules/nixos/tern-workspace-network.nix {
          inherit config lib pkgs;
          ternWorkspaceFixture = workspace;
        }
      )
      {
        # Provide only the Clan declaration interface; this VM never uses the
        # fleet's SOPS configuration or reads a deployed secret.
        options.clan.core.vars.generators = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              freeformType = lib.types.attrsOf lib.types.anything;
              options.files = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; };
            }
          );
        };
      }
    ];
    clan.core.vars.generators = {
      tern-workspace-wireguard.files.privatekey.path = privateKey;
      tern-workspace-dns.files.api-token.path = dnsToken;
    };
    # As on dev-01, networkd has an explicit uplink and no WireGuard netdev.
    # Only the production oneshot may create the workspace interface.
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.netdevs = lib.mkForce { };
    systemd.network.networks = lib.mkForce {
      "00-uplink" = {
        matchConfig.Name = "eth0";
        networkConfig.DHCP = "ipv4";
      };
    };
    networking.firewall = {
      enable = true;
      backend = "iptables";
      # Simulate the VPS's unrelated public listener, not the WG UDP rule.
      allowedTCPPorts = [ 443 ];
    };
    systemd.timers."acme-renew-${hostname}".enable = false;
    systemd.services = {
      # Keep the live Caddy unit and its certificate conditions; only replace
      # certificate issuance and external secret delivery with guest fixtures.
      "acme-${hostname}".enable = false;
      "acme-order-renew-${hostname}".enable = false;
      sops-install-secrets = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = with pkgs; [
          coreutils
          openssl
        ];
        script = ''
          set -euo pipefail
          umask 077
          install -d -m 0700 ${fixture} "$(dirname ${dnsToken})"
          cd ${fixture}
          printf %s 'Tern ingress VM server fixture' | openssl dgst -sha256 -binary | base64 >server.key
          printf %s 'Tern ingress VM client fixture' | openssl dgst -sha256 -binary | base64 >client.key
          printf '%s\n' 'fixture-not-a-cloudflare-token' >${dnsToken}

          openssl req -x509 -newkey ed25519 -noenc -days 1 -subj /CN=Ingress-test-CA \
            -addext basicConstraints=critical,CA:TRUE -keyout ca.key -out ca.crt
          openssl req -new -newkey ed25519 -noenc -subj /CN=${hostname} -keyout key.pem -out leaf.csr
          printf '%s\n' subjectAltName=DNS:${hostname} >leaf.ext
          openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
            -extfile leaf.ext -out fullchain.pem
          install -d -m 0750 -g tern-workspace-tls ${certDir}
          install -m 0640 -g tern-workspace-tls fullchain.pem key.pem ${certDir}
          touch ${certDir}/acme-success
        '';
      };
    };
    virtualisation = {
      memorySize = 1024;
      vlans = [ ];
    };
    environment.systemPackages = [ probe ];
    # Bring up the driver channel in stage one, including slow TCG boots.
    boot.initrd.kernelModules = [ "virtio_console" ];
    boot.kernelModules = [ "veth" ];
  };
  testScript = ''
    import select

    machine.start()
    assert machine.shell is not None
    assert select.select([machine.shell], [], [], 900)[0], "VM shell did not become ready"
    machine.connect()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("${wireguardService}")
    machine.wait_for_unit("tern-workspace-caddy.service")
    machine.succeed("${lib.getExe probe}")
  '';
}
