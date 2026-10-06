# The trusted launcher of the development hub's `dev-automation` Agent on
# dev-01 (atyrode/manifold packages/sdk/README.md, "Trusted launcher"). The
# operator registers the Agent once, on https://preview.manifold.tyrode.dev,
# and the hub shows its runner credential that once; from then on the
# credential lives only here.
#
#   custody    clan holds the runner token, per machine and prompted, never
#              minted -- the hub minted it -- as a secret sops-nix places
#              owned by root, mode 0400, so the operator's account cannot open
#              it. The Agent ID authorizes nothing and is an ordinary value in
#              the repository.
#   listener   systemd listens on /run/manifold-dev-launcher.sock, owned by the
#              operator's account and mode 0600, and starts one runner per
#              connection as a transient user. PID 1 loads the token for that
#              connection as a credential, so it is in no file the account can
#              read and in no process environment the account can inspect, and
#              a regenerated token is used from the next connection on.
#   runner     the SDK's manifold-action-runner, built from the `manifold`
#              input -- the preview owner pin, which follows the hub's
#              revision -- so the two speak one protocol. The connection is its
#              stdin and stdout: JSONL frames in, discovery, policy, result and
#              closed frames out. It deletes the binding from its environment
#              before it reads a frame, creates one root Run under the Agent's
#              standing grant, and settles and revokes that Run when it is
#              finished, abandoned at EOF, or cancelled by a signal.
#
# What the account gains is starting Runs inside that grant, never the token:
# the boundary the SDK README draws between a launcher and the agent driving
# it. Nothing listens until `clan vars generate dev-01 --generator
# manifold-dev-launcher` has stored both values.
{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  inherit (host) username;
  generator = config.clan.core.vars.generators.manifold-dev-launcher;
  origin = "https://preview.manifold.tyrode.dev";

  # Stated from sops-nix's fixed layout and asserted against clan's answer
  # once there is one, for the reason babel-archive.nix gives.
  placed = "/run/secrets/vars/manifold-dev-launcher/runner-token";
  reported = generator.files."runner-token".path;

  # The runner reads its binding from the environment only, so the token
  # passes from the credential file into this process's environment and is
  # gone from it once the runner starts.
  launch = pkgs.writeShellScript "manifold-dev-launcher" ''
    set -euo pipefail
    MANIFOLD_RUNNER_TOKEN="$(<"$CREDENTIALS_DIRECTORY/runner-token")"
    export MANIFOLD_RUNNER_TOKEN
    exec ${lib.getExe pkgs.manifold-dev-action-runner}
  '';
in
{
  assertions = [
    {
      assertion = reported == "/no-such-path" || reported == placed;
      message = "manifold-dev-launcher expects ${placed}, but sops-nix places it at ${reported}";
    }
  ];

  clan.core.vars.generators.manifold-dev-launcher = {
    # clan asks in name order: the Agent ID, then the token.
    prompts."agent-id" = {
      description = "MANIFOLD_AGENT_ID of the dev-automation Agent, as https://preview.manifold.tyrode.dev showed it at registration";
      type = "line";
    };
    prompts."runner-token" = {
      description = "MANIFOLD_RUNNER_TOKEN of the dev-automation Agent, shown that once beside it";
      type = "hidden";
    };

    files."runner-token" = {
      secret = true;
      owner = "root";
      group = "root";
      mode = "0400";
    };
    files."agent-id".secret = false;

    # The hub mints a runner token as 32 random bytes in lowercase hex and an
    # Agent ID as a UUID, and neither shape admits the other, so a swapped
    # paste fails here, without being quoted, instead of committing the token
    # as the public Agent ID.
    script = ''
      token="$(tr -d '[:space:]' <"$prompts/runner-token")"
      [[ "$token" =~ ^[0-9a-f]{64}$ ]] ||
        { echo "manifold-dev-launcher: runner-token is not a runner token" >&2; exit 1; }
      agent="$(tr -d '[:space:]' <"$prompts/agent-id")"
      [[ "$agent" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
        { echo "manifold-dev-launcher: agent-id is not an Agent ID" >&2; exit 1; }
      printf '%s\n' "$token" >"$out/runner-token"
      printf '%s\n' "$agent" >"$out/agent-id"
    '';
  };

  systemd = lib.mkIf generator.files."agent-id".exists {
    sockets.manifold-dev-launcher = {
      description = "Manifold development hub launcher for the dev-automation Agent";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "/run/manifold-dev-launcher.sock" ];
      socketConfig = {
        Accept = true;
        SocketUser = username;
        SocketMode = "0600";
        MaxConnections = 16;
      };
    };

    services."manifold-dev-launcher@" = {
      description = "Run one dev-automation Agent session on the Manifold development hub";
      environment = {
        MANIFOLD_ORIGIN = origin;
        MANIFOLD_AGENT_ID = lib.trim generator.files."agent-id".value;
        # The transient user has no writable home; Bun would otherwise try
        # to cache the runner's transpiled bundle there.
        BUN_RUNTIME_TRANSPILER_CACHE_PATH = "0";
      };
      # A failed session leaves its journal, not a failed unit per connection.
      unitConfig.CollectMode = "inactive-or-failed";
      serviceConfig = {
        ExecStart = launch;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        LoadCredential = "runner-token:${placed}";
        DynamicUser = true;
        # The runner ends itself after one hour; this only backstops it.
        RuntimeMaxSec = 3660;
        MemoryMax = "1G";
        UMask = "0077";
        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        LockPersonality = true;
        # No MemoryDenyWriteExecute: Bun's JIT maps writable code pages.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
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
        # HTTPS to the hub's public origin, which resolves through the local
        # stub resolver.
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        SystemCallErrorNumber = "EPERM";
      };
    };
  };
}
