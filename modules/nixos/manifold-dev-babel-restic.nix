# The storage service Babel's archive operations bind as `atyrode.babel.restic`
# on dev-01's native Manifold owner. A job never talks to this endpoint: it
# asks its owner's per-job proxy, and the owner forwards GET /storage here with
# the bearer it holds as the `babel-restic` service credential. The answer is
# the storage document modules/shared/babel-archive.nix already places on this
# machine, reduced to the four fields Babel's machine half reads
# ({repository, password, accessKeyId, secretAccessKey}). Nothing is minted
# beyond the loopback bearer, and nothing new is placed on disk.
#
#   bearer     32 random bytes placed per boot in a runtime directory, before
#              the owner starts: owned by manifold, mode 0600, never in the Nix
#              store. It is never replaced while it exists, because the owner
#              holds the inode it opened at start and refuses a relinked one.
#   listener   systemd listens on 127.0.0.1 only and starts one short-lived
#              process per connection. That process has no network of its own,
#              runs as a transient user, and reads the bearer, the document and
#              the repository password as credentials PID 1 loads for that
#              connection, so a regenerated document is served on the next one.
#   answer     only GET /storage with the exact bearer; anything else is refused
#              and no value is ever logged.
#
# Host-network jobs can reach the port, but not the bearer: the owner never
# hands a job an upstream credential, and the bearer's directory is excluded
# from every workload mount.
{ pkgs, ... }:
let
  port = 7811;
  origin = "http://127.0.0.1:${toString port}";
  runtimeDirectory = "babel-restic-storage";
  bearer = "/run/${runtimeDirectory}/bearer";
  # sops-nix's placement of the babel-archive var; babel-archive.nix asserts it
  # against clan's reported paths.
  storageDocument = "/run/secrets/vars/babel-archive/storage.json";
  passwordFile = "/run/secrets/vars/babel-archive/repository-password";
  server = pkgs.writers.writePython3 "babel-restic-storage" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./manifold-dev-babel-restic.py);
in
{
  services.manifold.execution.serviceCredentials.babel-restic = {
    source = bearer;
    origins = [ origin ];
  };

  systemd.services.babel-restic-storage-bearer = {
    description = "Place the bearer Manifold presents to Babel's restic storage endpoint";
    wantedBy = [ "multi-user.target" ];
    before = [ "manifold-owner.service" ];
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      directory=/run/${runtimeDirectory}
      bearer=${bearer}
      if [[ -e "$bearer" || -L "$bearer" ]]; then
        # Keep the one the owner opened; a replacement would strand its descriptor.
        [[ "$(stat -c '%F:%U:%G:%a:%h' "$bearer")" == 'regular file:manifold:manifold:600:1' ]] || {
          echo "babel-restic-storage: $bearer is not a single-link manifold-owned 0600 file; not replacing it" >&2
          exit 1
        }
        exit 0
      fi
      scratch="$(mktemp "$directory/.bearer.XXXXXX")"
      trap 'rm -f -- "$scratch"' EXIT
      head -c 32 /dev/urandom | basenc --base64url -w 0 >"$scratch"
      chown manifold:manifold "$scratch"
      mv -T -- "$scratch" "$bearer"
      trap - EXIT
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      # The directory is root:manifold 0710: the owner may traverse it to open
      # the bearer, and the owner's custody check accepts a root-owned parent
      # that no group or other can write. It survives restarts until reboot.
      Group = "manifold";
      RuntimeDirectory = runtimeDirectory;
      RuntimeDirectoryMode = "0710";
      RuntimeDirectoryPreserve = true;
      UMask = "0077";
      CapabilityBoundingSet = [ "CAP_CHOWN" ];
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    };
  };

  # The owner fails to start without its declared credential source, so the
  # bearer comes first. Wants rather than Requires: a restart of this oneshot
  # must never propagate to the retained owner.
  systemd.services.manifold-owner = {
    wants = [ "babel-restic-storage-bearer.service" ];
    after = [ "babel-restic-storage-bearer.service" ];
  };

  systemd.sockets.babel-restic-storage = {
    description = "Babel restic storage endpoint for the Manifold owner (loopback)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:${toString port}" ];
    socketConfig = {
      Accept = true;
      MaxConnections = 8;
      IPAddressAllow = "localhost";
      IPAddressDeny = "any";
    };
  };

  systemd.services."babel-restic-storage@" = {
    description = "Answer one Babel restic storage request";
    requires = [ "babel-restic-storage-bearer.service" ];
    after = [ "babel-restic-storage-bearer.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3.interpreter} -I -B ${server} ${passwordFile}";
      LoadCredential = [
        "bearer:${bearer}"
        "storage.json:${storageDocument}"
        "repository-password:${passwordFile}"
      ];
      DynamicUser = true;
      CollectMode = "inactive-or-failed";
      RuntimeMaxSec = 30;
      MemoryMax = "64M";
      TasksMax = 4;
      UMask = "0077";
      CapabilityBoundingSet = "";
      DevicePolicy = "closed";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      PrivateUsers = true;
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      RemoveIPC = true;
      RestrictAddressFamilies = "none";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
    };
  };
}
