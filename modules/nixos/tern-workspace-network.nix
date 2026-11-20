{
  config,
  lib,
  pkgs,
  ...
}:
let
  workspace = import ../../fleet/tern-workspace.nix;
  inherit (workspace)
    hostname
    interface
    proxyPort
    serverAddress
    webPort
    ;
  peers = lib.filterAttrs (_: peer: peer.publicKey != null) workspace.peers;
  vars = config.clan.core.vars.generators;
  wireguardKey = vars.tern-workspace-wireguard.files.privatekey;
  dnsToken = vars.tern-workspace-dns.files.api-token;
  wireguardReady = workspace.serverPublicKey != null && wireguardKey.exists;

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
      assertions = [
        {
          assertion = config.networking.firewall.enable && config.networking.firewall.backend == "iptables";
          message = "Tern workspace ingress requires the VPS's iptables firewall backend.";
        }
      ];

      networking.wireguard.interfaces.${interface} = {
        ips = [ "${serverAddress}/32" ];
        privateKeyFile = wireguardKey.path;
        listenPort = workspace.port;
        peers = lib.mapAttrsToList (name: peer: {
          inherit name;
          inherit (peer) publicKey;
          allowedIPs = [ "${peer.address}/32" ];
        }) peers;
      };

      networking.firewall.interfaces.${interface}.allowedTCPPorts = [ proxyPort ];

      systemd.services.${wireguardService} = {
        bindsTo = [ "${ingressService}.service" ];
        partOf = [ "${ingressService}.service" ];
        after = [ "${ingressService}.service" secretInstallUnit ];
        unitConfig.ConditionFileNotEmpty = wireguardKey.path;
      };

      # Own these hooks outside the VPS firewall's non-atomic reload lifecycle.
      # Install before WireGuard gets its IP, and remove only after it stops.
      # The raw guard precedes NAT and checks the actual ingress interface. A
      # packet sent to the private address on any other interface must not reach
      # the public wildcard listener, even if the main firewall is reloading.
      systemd.services.${ingressService} = {
        description = "Restrict and translate IPv4 Tern workspace ingress";
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
          '') (lib.attrValues peers)}
          iptables -w -t raw -A ${ingressChain} -i ${interface} -j DROP
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

    (lib.mkIf (wireguardReady && dnsToken.exists) {
      users.groups.${tlsGroup} = { };

      security.acme = {
        acceptTerms = true;
        certs.${hostname} = {
          email = null;
          dnsProvider = "cloudflare";
          enableDebugLogs = false;
          credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = dnsToken.path;
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
        unitConfig.ConditionFileNotEmpty = dnsToken.path;
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
          ConditionFileNotEmpty = dnsToken.path;
          # NixOS initially puts a self-signed certificate in the same paths.
          # Serve nothing until ACME has issued a real certificate.
          ConditionPathExists = "${certDir}/acme-success";
        };
        environment.XDG_DATA_HOME = "/var/lib/${caddyService}";
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.caddy} run --config ${caddyfile} --adapter caddyfile";
          DynamicUser = true;
          SupplementaryGroups = [ tlsGroup ];
          StateDirectory = caddyService;
          StateDirectoryMode = "0700";
        };
      };
    })
  ];
}
