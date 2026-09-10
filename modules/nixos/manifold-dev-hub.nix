# The public front of the manifold preview tier on the VPS. Caddy answers
# `preview.manifold.tyrode.dev` -- the integrated instance, every green
# `main`, on the compose stack the operator runs from a checkout on port
# 7912 -- and `*.manifold.tyrode.dev`, one hostname per pull request or live
# worktree, proxied to the operator-owned router on 127.0.0.1:7900 that
# manifold's `infra/previews/preview.sh` generates as previews come and go.
# The stable hub -- `fleet/manifold.json`'s masterUrl -- is elsewhere
# (Clever Cloud, atyrode/manifold ADR 0022); this machine hosts only what
# one iterates on, and is a spoke of the stable one like every other.
#
# Certificates for BOTH vhosts are issued ON DEMAND, per hostname, on first
# request, and only for hostnames the router vouches for (`/__preview/ask`
# answers 200 for `preview.` and every registered preview, 404 otherwise), so
# a stray name under the wildcard never costs a certificate. A DNS-validated
# wildcard certificate would need a DNS plugin and the zone token in Caddy's
# hands; on-demand issuance needs neither. `preview.` cannot be a managed
# name: Caddy 2.10+ treats a name covered by a wildcard site block as served
# by the wildcard's certificate and skips its own issuance, and an on-demand
# wildcard never issues eagerly -- with a managed policy, `preview.` answered
# every handshake with `internal error` (dev-01, 2026-09-05).
#
# Ports 80 and 443 are the VPS's reviewed exposure beyond SSH, shared with
# myparcelle-dev.nix: modules/nixos/vps.nix opens exactly that set.
# The stacks themselves (images, data volumes, restarts) are not declared
# here: they are the operator's checkouts, started by the receiver the deploy
# key runs (`modules/home/ssh/deploy-keys`), and a vhost whose upstream is down
# answers 502, which is the state "not running" should
# have -- never a fallback to some other hub.
{
  config,
  host,
  pkgs,
  ...
}:
let
  inherit (host) homeDirectory username;
  serviceOwnerMachineId = "05df7eaa-efd8-4d9c-bb0c-334706555c77";
  loader =
    if pkgs.stdenv.hostPlatform.isAarch64 then "ld-linux-aarch64.so.1" else "ld-linux-x86-64.so.2";
  libraries = [
    "libc.so.6"
    "libdl.so.2"
    "libm.so.6"
    "libpthread.so.0"
    "libutil.so.1"
    loader
  ];
  libraryBindings =
    target:
    map (name: {
      source = "${pkgs.glibc}/lib/${name}";
      target = "${target}/${name}";
      kind = "file";
    }) libraries;
  developmentRuntime = pkgs.buildEnv {
    name = "manifold-preview-development-runtime";
    paths = with pkgs; [
      bash
      coreutils
      findutils
      gnused
      gnugrep
      gawk
      diffutils
      patch
      gitMinimal
      gh
      curl
      ripgrep
      fd
      jq
      python3
    ];
    pathsToLink = [ "/bin" ];
  };
in
{
  services.manifold = {
    enable = true;
    hub.enable = false;
    execution = {
      enable = true;
      machineName = "dev-01";
      serverUrl = "https://preview.manifold.tyrode.dev";
      machineId = serviceOwnerMachineId;
      admissionPublicKey = ''
        -----BEGIN PUBLIC KEY-----
        MCowBQYDK2VwAyEAI/Pr5NQBY5sqj80suvdcAffkVgMMauD21FAoUvT45oo=
        -----END PUBLIC KEY-----
      '';
      tokenCredentialFile = "${homeDirectory}/.config/manifold/dev/machine.token";
      # The incumbent token lives beneath the operator's private home. Protect
      # its traversable ancestor instead of weakening that home's permissions.
      protectedDirectories = [ "/home" ];
      artifactOrigins = [
        "https://github.com"
        "https://release-assets.githubusercontent.com"
        "https://registry.npmjs.org"
      ];
      # Published runtimes use FHS interpreter paths. Coding tools receive their
      # explicitly selected Nix closures separately, never the ambient store.
      runtimeTools.system =
        libraryBindings "/lib"
        ++ [
          {
            source = "/run/systemd/resolve/stub-resolv.conf";
            target = "/etc/resolv.conf";
            kind = "file";
          }
          {
            source = toString config.environment.etc."ssl/certs/ca-certificates.crt".source;
            target = "/etc/ssl/certs/ca-certificates.crt";
            kind = "file";
          }
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [
          {
            source = "${pkgs.glibc}/lib/${loader}";
            target = "/lib64/${loader}";
            kind = "file";
          }
        ];
      runtimeTools.development = [
        {
          source = "${developmentRuntime}/bin";
          target = "/usr/bin";
          kind = "directory";
        }
        {
          source = "${pkgs.bash}/bin/bash";
          target = "/bin/sh";
          kind = "file";
        }
        {
          source = "${pkgs.bash}/bin/bash";
          target = "/bin/bash";
          kind = "file";
        }
      ];
      runtimeToolClosures.development = [ developmentRuntime ];
    };
  };
  # Recheck supervisor truth on every start, before the native profile publishes
  # private owner configuration or PID 1 loads the transport credential. This is
  # a prerequisite, not a retirement operation or a persistent "retired" marker.
  systemd.services.manifold-preview-legacy-guard = {
    description = "Require retired preview user supervisors before native startup";
    script = ''
      set -euo pipefail
      refuse() {
        echo "Manifold preview native startup blocked: $*; complete authorized old-spoke retirement first" >&2
        exit 1
      }

      # NixOS allocates this existing account's UID at activation; resolve the
      # public identity instead of assigning a new UID or reading private state.
      uid="$(${pkgs.coreutils}/bin/id -u ${pkgs.lib.escapeShellArg username})"
      manager="user@$uid.service"
      # An absent user bus is not evidence of retirement. Start its manager and
      # wait for it explicitly; later manager restarts must not stop the owner.
      ${config.systemd.package}/bin/systemctl start -- "$manager" \
        || refuse "owning user manager could not start"
      ${config.systemd.package}/bin/systemctl is-active --quiet -- "$manager" \
        || refuse "owning user manager is not active"

      for unit in manifold-dev-terminal-host.service manifold-dev-agent.service; do
        metadata="$(${config.systemd.package}/bin/systemctl --user \
          --machine=${pkgs.lib.escapeShellArg "${username}@.host"} show --all \
          --property=LoadState,ActiveState,SubState,UnitFileState,Job,NeedDaemonReload,TriggeredBy,UpheldBy \
          -- "$unit")" || refuse "$unit metadata is unavailable"
        declare -A state=()
        while IFS='=' read -r key value; do
          case "$key" in
            LoadState|ActiveState|SubState|UnitFileState|Job|NeedDaemonReload|TriggeredBy|UpheldBy)
              [[ ! -v "state[$key]" ]] || refuse "$unit metadata is ambiguous"
              state[$key]="$value"
              ;;
            *) refuse "$unit metadata is unrecognized" ;;
          esac
        done <<< "$metadata"
        [[ "''${#state[@]}" == 8 ]] || refuse "$unit metadata is incomplete"
        [[ "''${state[ActiveState]}" == inactive && "''${state[SubState]}" == dead ]] \
          || refuse "$unit is not stopped"
        [[ "''${state[NeedDaemonReload]}" == no && -z "''${state[Job]}" \
          && -z "''${state[TriggeredBy]}" && -z "''${state[UpheldBy]}" ]] \
          || refuse "$unit has stale metadata or a queued/triggered supervisor"
        case "''${state[LoadState]}:''${state[UnitFileState]}" in
          loaded:disabled|loaded:masked|masked:masked|not-found:)
            ;;
          *) refuse "$unit is enabled, restartable or in an uncertain load state" ;;
        esac
      done
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      TimeoutStartSec = 90;
    };
  };
  systemd.services.manifold-owner.requires = [ "manifold-preview-legacy-guard.service" ];
  systemd.services.manifold-transport.requires = [ "manifold-preview-legacy-guard.service" ];
  systemd.services.manifold-transport.after = [ "manifold-preview-legacy-guard.service" ];
  # Start after the existing resolver without coupling owner lifetime to its restarts.
  systemd.services.manifold-owner.after = [
    "systemd-resolved.service"
    "manifold-preview-legacy-guard.service"
  ];
  systemd.services.manifold-owner.wants = [ "systemd-resolved.service" ];
  systemd.services.manifold-owner.unitConfig."X-Atyrode-SessionOwner" = true;
  systemd.services.manifold-transport.unitConfig."X-Atyrode-SessionOwner" = false;
  # These public receiver choices must travel with the native owner declaration,
  # so a later hub deployment cannot revive the retired user-spoke helper.
  home-manager.users.${username}.home.file."manifold-previews/env".text = ''
    PREVIEW_DOMAIN=manifold.tyrode.dev
    PREVIEW_DEV_CHECKOUT=${homeDirectory}/manifold-dev
    PREVIEW_DEV_URL=https://preview.manifold.tyrode.dev
    PREVIEW_SEED=${homeDirectory}/manifold-dev-deploy/backups/manifold-dev-data-20260905T131810Z.tgz
    MANIFOLD_DEV_SERVICE_OWNER_MACHINE_ID=${serviceOwnerMachineId}
    MANIFOLD_DEV_SPAWN_AGENT=0
  '';
  services.caddy = {
    enable = true;
    globalConfig = ''
      on_demand_tls {
        ask http://127.0.0.1:7900/__preview/ask
      }
    '';
    virtualHosts."preview.manifold.tyrode.dev".extraConfig = ''
      tls {
        on_demand
      }

      encode zstd gzip

      header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
      }

      reverse_proxy 127.0.0.1:7912
    '';
    virtualHosts."*.manifold.tyrode.dev".extraConfig = ''
      tls {
        on_demand
      }

      encode zstd gzip

      header {
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
      }

      reverse_proxy 127.0.0.1:7900
    '';
  };
}
