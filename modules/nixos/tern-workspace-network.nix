{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  workspace = args.ternWorkspaceFixture or (import ../../fleet/tern-workspace.nix);
  inherit (workspace)
    hostname
    interface
    nativePort
    proxyPort
    serverAddress
    webPort
    ;
  peers = lib.attrValues (lib.filterAttrs (_: peer: peer.publicKey != null) workspace.peers);
  nativePeers = lib.attrValues (workspace.selectNativePeers workspace.peers);
  nativeEnabled = nativePeers != [ ];
  peerArgs = lib.concatMap (peer: [
    "peer"
    peer.publicKey
    "allowed-ips"
    "${peer.address}/32"
  ]) peers;
  vars = config.clan.core.vars.generators;
  wireguardKey = vars.tern-workspace-wireguard.files.privatekey;
  dnsToken = vars.tern-workspace-dns.files.api-token;
  # Clan exposes the public half at evaluation time. Secret presence is a
  # runtime question: only the host can check what sops has placed.
  wireguardReady = workspace.serverPublicKey != null;
  dnsTokenPath = "/run/secrets/vars/tern-workspace-dns/api-token";

  wireguardService = "wireguard-${interface}";
  ingressService = "tern-workspace-ingress";
  caddyService = "tern-workspace-caddy";
  tlsGroup = "tern-workspace-tls";
  certDir = "/var/lib/acme/${hostname}";
  acmeOrder = "acme-order-renew-${hostname}";
  secretInstallUnit = "sops-install-secrets.service";
  ingressChain = "tern-workspace";

  caddyfile = pkgs.writeText "tern-workspace.Caddyfile" ''
    {
      admin off
      persist_config off
      auto_https off
      servers {
        protocols h1 h2
        strict_sni_host on
      }
      log {
        # Even the HTTP runtime error logger can include a token-bearing URL.
        exclude http
      }
    }

    https://${hostname}:${toString proxyPort} {
      bind ${serverAddress}
      tls ${certDir}/fullchain.pem ${certDir}/key.pem
      header Referrer-Policy "no-referrer"

      @wrongOrigin {
        header Origin *
        expression `{http.request.header.Origin} != "https://${hostname}"`
      }
      @wrongWireOrigin {
        path /wire /wire/*
        expression `{http.request.header.Origin} != "https://${hostname}"`
      }
      respond @wrongOrigin 403
      respond @wrongWireOrigin 403
      reverse_proxy 127.0.0.1:${toString webPort}
    }
  '';
in
{
  imports = [ ../shared/tern-workspace-wireguard.nix ];

  config = lib.mkMerge [
    {
      clan.core.vars.generators.tern-workspace-dns = {
        prompts.api-token = {
          description = "Cloudflare token with Zone:Read and DNS:Edit for the Tern DNS-01 validation zone only";
          type = "hidden";
        };
        files.api-token = {
          secret = true;
          owner = "root";
          group = "root";
          mode = "0600";
        };
        script = ''
          token=$(cat "$prompts/api-token")
          [[ "$token" =~ ^[A-Za-z0-9_-]{32,}$ ]] ||
            { echo "tern-workspace-dns: api-token is not a Cloudflare API token" >&2; exit 1; }
          printf '%s\n' "$token" > "$out/api-token"
        '';
      };
    }

    (lib.mkIf wireguardReady {
      boot.kernelModules = [ "wireguard" ];
      boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = lib.mkDefault 1024;
      assertions = [
        {
          assertion = config.networking.firewall.enable && config.networking.firewall.backend == "iptables";
          message = "Tern workspace ingress requires the VPS's iptables firewall backend.";
        }
        {
          assertion =
            lib.toInt (toString config.boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start")
            > lib.max webPort (lib.max proxyPort (if nativeEnabled then nativePort else 0));
          message = "Private Tern listeners must be in the privileged port range.";
        }
        {
          assertion = dnsToken.path == "/no-such-path" || dnsToken.path == dnsTokenPath;
          message = "Tern expects its DNS-01 credential at ${dnsTokenPath}.";
        }
      ];

      networking.firewall = {
        # Merge at the priority of the reviewed VPS UDP allowlist.
        allowedUDPPorts = lib.mkForce [ workspace.port ];
        interfaces.${interface} = {
          allowedTCPPorts = [ proxyPort ];
          allowedUDPPorts = lib.mkIf nativeEnabled [ nativePort ];
        };
      };

      systemd.services.${wireguardService} = {
        # dev-01 uses networkd for its static uplink. Keep this interface under
        # one service so neither networkd nor a generated peer unit can assign
        # its addresses before the ingress hooks are active.
        description = "Private Tern workspace WireGuard tunnel";
        wantedBy = [ "multi-user.target" ];
        bindsTo = [ "${ingressService}.service" ];
        partOf = [ "${ingressService}.service" ];
        after = [
          "${ingressService}.service"
          secretInstallUnit
        ];
        unitConfig.ConditionFileNotEmpty = wireguardKey.path;
        path = [
          pkgs.iproute2
          pkgs.wireguard-tools
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          LoadCredential = [ "privatekey:${wireguardKey.path}" ];
          CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        };
        script = ''
          ip link add dev ${interface} type wireguard
          trap 'ip link delete dev ${interface}' EXIT
          wg set ${interface} private-key "$CREDENTIALS_DIRECTORY/privatekey" \
            listen-port ${toString workspace.port} ${lib.escapeShellArgs peerArgs}
          ip -4 address add ${serverAddress}/32 dev ${interface}
          ip link set dev ${interface} up
          ${lib.concatMapStringsSep "\n" (peer: ''
            ip -4 route add ${peer.address}/32 dev ${interface} src ${serverAddress}
          '') peers}
          trap - EXIT
        '';
        preStop = "ip link delete dev ${interface}";
      };

      # Own these hooks outside the VPS firewall's non-atomic reload lifecycle.
      # Install before WireGuard gets its IP, and remove only after it stops.
      # The raw guard precedes NAT and checks the actual ingress interface. A
      # packet sent to the private address on any other interface must not reach
      # the public wildcard listener, even if the main firewall is reloading.
      systemd.services.${ingressService} = {
        description = "Restrict and translate IPv4 Tern workspace ingress";
        bindsTo = [ "firewall.service" ];
        partOf = [ "firewall.service" ];
        after = [ "firewall.service" ];
        path = [ config.networking.firewall.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          iptables -w -t raw -N ${ingressChain}
          ${lib.concatMapStringsSep "\n" (peer: ''
            iptables -w -t raw -A ${ingressChain} -i ${interface} -s ${peer.address}/32 \
              -d ${serverAddress}/32 -p tcp --dport 443 -j RETURN
          '') peers}
          ${
            lib.concatMapStrings (peer: ''
              iptables -w -t raw -A ${ingressChain} -i ${interface} -s ${peer.address}/32 \
                -d ${serverAddress}/32 -p udp --dport ${toString nativePort} -j RETURN
            '') nativePeers
          }iptables -w -t raw -A ${ingressChain} -i ${interface} -j DROP
          iptables -w -t raw -A ${ingressChain} -d ${serverAddress}/32 -j DROP
          iptables -w -t raw -I PREROUTING -j ${ingressChain}

          iptables -w -t nat -N ${ingressChain}
          iptables -w -t nat -A ${ingressChain} -i ${interface} -d ${serverAddress}/32 \
            -p tcp --dport 443 -j DNAT --to-destination ${serverAddress}:${toString proxyPort}
          iptables -w -t nat -I PREROUTING -j ${ingressChain}

          # This interface is never a way to route packets between hosts.
          for direction in -i -o; do
            iptables -w -I FORWARD "$direction" ${interface} -m comment --comment ${ingressChain} -j DROP
          done
        '';
        postStop = ''
          for direction in -i -o; do
            if iptables -w -C FORWARD "$direction" ${interface} -m comment --comment ${ingressChain} -j DROP 2>/dev/null; then
              iptables -w -D FORWARD "$direction" ${interface} -m comment --comment ${ingressChain} -j DROP
            fi
          done
          for table in nat raw; do
            if iptables -w -t "$table" -S ${ingressChain} >/dev/null 2>&1; then
              if iptables -w -t "$table" -C PREROUTING -j ${ingressChain} 2>/dev/null; then
                iptables -w -t "$table" -D PREROUTING -j ${ingressChain}
              fi
              iptables -w -t "$table" -F ${ingressChain}
              iptables -w -t "$table" -X ${ingressChain}
            fi
          done
        '';
      };
    })

    (lib.mkIf wireguardReady {
      users.groups.${tlsGroup} = { };

      security.acme = {
        acceptTerms = true;
        certs.${hostname} = {
          email = null;
          dnsProvider = "cloudflare";
          enableDebugLogs = false;
          credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = dnsTokenPath;
          group = tlsGroup;
          # Lego follows a public _acme-challenge CNAME if validation uses a
          # delegated zone. Only systemd and the isolated renewer see the token.
          postRun = ''
            ${pkgs.systemd}/bin/systemctl --no-block restart ${caddyService}.service
          '';
        };
      };

      systemd.services.${acmeOrder} = {
        after = [ secretInstallUnit ];
        unitConfig.ConditionFileNotEmpty = dnsTokenPath;
      };

      systemd.services.${caddyService} = {
        description = "Private Tern workspace HTTPS proxy";
        wantedBy = [ "${wireguardService}.service" ];
        bindsTo = [ "${wireguardService}.service" ];
        partOf = [ "${wireguardService}.service" ];
        wants = [ "acme-${hostname}.service" ];
        after = [
          "${wireguardService}.service"
          "${acmeOrder}.service"
          secretInstallUnit
        ];
        unitConfig = {
          ConditionFileNotEmpty = dnsTokenPath;
          # NixOS initially puts a self-signed certificate in the same paths.
          # Serve nothing until ACME has issued a real certificate.
          ConditionPathExists = "${certDir}/acme-success";
        };
        environment.XDG_DATA_HOME = "/var/lib/${caddyService}";
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.caddy} run --config ${caddyfile} --adapter caddyfile";
          DynamicUser = true;
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
          SocketBindDeny = "any";
          SocketBindAllow = "ipv4:tcp:${toString proxyPort}";
          SupplementaryGroups = [ tlsGroup ];
          StateDirectory = caddyService;
          StateDirectoryMode = "0700";
        };
      };
    })
  ];
}
