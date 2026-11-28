# ci-01: the dedicated GitHub Actions runner host for myParcelle's CI
# (myParcelle's deploy/README.md § The ci-01 host contract). The runners follow
# the same shape as dev-01's (myparcelle-ci-runners.nix), which this module
# does not touch; what differs is stated here so a reader of one need not
# diff the other.
#
#   user       `myparcelle-ci`, a system account with its own home under
#              /var/lib and its own rootless Docker engine; no wheel, no
#              docker group, no SSH login, no access to /home.
#   isolation  every job runs in a fresh pair of containers in that engine: a
#              privileged `docker:dind` sibling (the job's own engine, for
#              `services:`, buildx and compose, with its own /var/lib/docker
#              volume) and the myParcelle runner image sharing its network
#              namespace, so every job has its own loopback and ports. Both,
#              and their volumes, are deleted when the job ends. The engine is
#              privileged only inside the account's rootless user namespace:
#              it holds nothing of the host, and the rootless engine hides
#              the host's loopback from containers.
#   ephemeral  each start mints a just-in-time runner configuration: one
#              runner, one job, then it de-registers and the unit restarts.
#   credential the long-lived GitHub token that mints those configurations is
#              the clan var `myparcelle-ci-github-token` (a fine-grained token
#              on the one repository, Administration: write), placed root-only
#              by sops-nix. Only root's ExecStartPre reads it; the CI account
#              receives the single-use runner configuration and nothing else.
#   labels     all slots carry `self-hosted linux x64 ci-01`; `ci-01-heavy`
#              and `ci-01-small` select capacity, never privilege. Names are
#              `ci-01-<slot>-<epoch>`.
#   image      the public image myParcelle publishes, pinned by digest like
#              every other input of this repository (Chromium, Firefox and
#              WebKit included). To follow a new image, bump `runnerImage` from
#              `bun deploy/ci-runners/image.ts digest` in a myParcelle checkout.
#
# Sizing (a starting point, tuned from the queue's real load). The machine has
# 12 shared vCPUs and 32 GiB; about 3 GiB stay with the host (kernel, sshd, the
# mirror, a deployment's Nix evaluation), so the account's slice is held to
# 29 GiB. Each slot's engine (DinD) has its own limit, 2.5 GiB on the large
# slots (Keycloak peaked at 2.16 GiB) and 0.5 GiB on the small ones. The
# runner containers deliberately have NO memory limit, as on dev-01: the
# application under test reads its cgroup's memory.max and refuses heavy
# document work near it, and counts page cache. With a 4 GiB runner limit its
# `bun` lane failed (plu-admin-questions-documents, cgroupBytes 2.9 GB) though
# nothing was OOM-killed; with 2.5 GiB the types lane was OOM-killed (exit 137).
# The trade-off: no per-runner memory wall. A runaway job can take memory from
# the other slots up to the account slice's 29 GiB, never the host's 3 GiB
# reserve. Two large slots own four CPUs each (0–7), three small slots share
# 8–11 and see two (by affinity mask). CPU weight 50 and an 11-core quota favour
# the host under contention.
#
# Isolation: each slot has its own network and no shared host-writable mount.
# Jobs use GitHub Actions' ref-scoped cache, not a host browser-build store.
#
# Network: jobs reach the public internet only (nftables table below); ci-01
# is not on the fleet overlay at all.
#
# Each fresh engine uses the same public Docker Hub mirror as myParcelle's
# Clever runners. There is no shared on-host registry cache or Bun generation.
{
  config,
  lib,
  machineDirectory,
  pkgs,
  ...
}:
let
  machineAddress = import (machineDirectory + "/address.nix");
  user = "myparcelle-ci";
  uid = 940;
  home = "/var/lib/${user}";
  runtimeDir = "/run/user/${toString uid}";
  dockerHost = "unix://${runtimeDir}/docker.sock";
  docker = config.virtualisation.docker.rootless.package;

  repository = "tyrode-dev/myParcelle";
  labels = [
    "self-hosted"
    "linux"
    "x64"
    "ci-01"
  ];
  small = {
    engine = "512m";
    labels = labels ++ [ "ci-01-small" ];
  };
  large = {
    engine = "2560m";
    labels = labels ++ [ "ci-01-heavy" ];
  };
  slots = [
    (large // { cpus = "0-3"; })
    (large // { cpus = "4-7"; })
    (small // { cpus = "8-9"; })
    (small // { cpus = "10-11"; })
    (small // { cpus = "8-9"; })
  ];
  slotNumbers = lib.range 1 (builtins.length slots);
  slotOf = number: builtins.elemAt slots (number - 1);

  # Root-only, placed by sops-nix from the clan var below.
  tokenFile = "/run/secrets/vars/myparcelle-ci-github-token/token";
  reported = config.clan.core.vars.generators.myparcelle-ci-github-token.files."token".path;

  # A distinct user-defined bridge for each runner/engine pair.
  slotNetwork = slot: "myparcelle-ci-${toString slot}";

  runnerImage = "ghcr.io/tyrode-dev/myparcelle-ci-runner@sha256:7f9557c849ad3c9e2d8c15510373800e4cc2aefd6725fceefa95de6cf60efe4b";
  dindImage = "docker:28.5.2-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac";
  innerDaemonConfig = builtins.toJSON {
    ipv6 = false;
    ip6tables = false;
    registry-mirrors = [ "https://mirror.gcr.io" ];
  };

  dockerEnvironment = [
    "DOCKER_HOST=${dockerHost}"
    "XDG_RUNTIME_DIR=${runtimeDir}"
    "HOME=${home}"
  ];

  # Root owns the slot's runtime directory. Only the single-use configuration
  # leaves it, on the downgraded job process's stdin. The token reaches curl
  # on stdin, never argv or the environment.
  mintRunner = pkgs.writeShellApplication {
    name = "myparcelle-ci-mint-runner";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      slot=$1
      labels=$2
      [[ -s ${tokenFile} ]] || {
        echo "myparcelle-ci: ${tokenFile} is not placed; the runner waits for it" >&2
        exit 1
      }
      body=$(jq -cn --arg name "ci-01-$slot-$(date +%s)" --argjson labels "$labels" \
        '{name: $name, runner_group_id: 1, labels: $labels, work_folder: "_work"}')
      umask 077
      response=$(printf 'Authorization: Bearer %s\n' "$(<${tokenFile})" |
        curl -q --silent --show-error --fail --max-time 30 -H @- \
          -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
          --data "$body" https://api.github.com/repos/${repository}/actions/runners/generate-jitconfig)
      jq -er '.runner.id | select(type == "number" and . > 0 and floor == .)' \
        <<<"$response" >"$RUNTIME_DIRECTORY/runner-id"
      jq -er '.encoded_jit_config | strings | select(test("^[A-Za-z0-9+/=]+$"))' \
        <<<"$response" >"$RUNTIME_DIRECTORY/jitconfig"
    '';
  };

  # Root, after the unit stops: a runner minted but never connected is removed
  # rather than left offline. A runner that ran its job is already gone, and
  # the 404 is expected.
  forgetRunner = pkgs.writeShellApplication {
    name = "myparcelle-ci-forget-runner";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      id_file="$RUNTIME_DIRECTORY/runner-id"
      [[ -s $id_file && -s ${tokenFile} ]] || exit 0
      id=$(<"$id_file")
      printf 'Authorization: Bearer %s\n' "$(<${tokenFile})" |
        curl -q --silent --output /dev/null --max-time 30 -H @- -X DELETE \
          -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
          "https://api.github.com/repos/${repository}/actions/runners/$id" || true
    '';
  };

  removeJob = pkgs.writeShellApplication {
    name = "myparcelle-ci-remove-job";
    runtimeInputs = [
      docker
      pkgs.gnugrep
    ];
    text = ''
      name=myparcelle-ci-runner-$1
      docker rm --force --volumes "$name" "$name-engine" >/dev/null 2>&1 || true
      docker volume rm --force "$name-work" "$name-socket" "$name-data" >/dev/null 2>&1 || true

      # Absence must be verified by a successful list, including when a
      # daemon outage made the remove calls above fail.
      containers=$(docker container ls --all --format '{{.Names}}')
      volumes=$(docker volume ls --format '{{.Name}}')
      if grep -Fxq -e "$name" -e "$name-engine" <<<"$containers" ||
         grep -Fxq -e "$name-work" -e "$name-socket" -e "$name-data" <<<"$volumes"; then
        echo "Job objects still present after teardown: $name" >&2
        exit 1
      fi
    '';
  };

  # The CI account: one job in fresh containers, then exit; systemd restarts
  # the unit, which mints the next runner.
  runJob = pkgs.writeShellApplication {
    name = "myparcelle-ci-run-job";
    runtimeInputs = [ docker ];
    text = ''
      slot=$1
      cpus=$2
      engine_memory=$3
      network=$4
      name=myparcelle-ci-runner-$slot
      IFS= read -r ACTIONS_RUNNER_INPUT_JITCONFIG
      export ACTIONS_RUNNER_INPUT_JITCONFIG

      # The job's engine. Its socket, its image store and the job's workspace
      # are volumes; the socket and the workspace are mounted by both
      # containers at the same paths, so bind mounts a job asks the engine for
      # (compose files, build contexts) resolve to the same files.
      # No IPv6 egress beyond the job's own throwaway engine. The runner
      # shares this IPv4-only namespace, and RootlessKit has no IPv6. The
      # inner daemon defaults to IPv4-only; a job may still create its own
      # private IPv6 network inside its disposable engine.
      docker run --detach --rm --privileged --name "$name-engine" --network "$network" \
        --cpuset-cpus "$cpus" --memory="$engine_memory" --memory-swap="$engine_memory" \
        --sysctl net.ipv6.conf.all.disable_ipv6=1 \
        --sysctl net.ipv6.conf.default.disable_ipv6=1 \
        --env DOCKER_TLS_CERTDIR= \
        --volume "$name-socket:/var/run/engine" --volume "$name-work:/home/runner/_work" \
        --volume "$name-data:/var/lib/docker" \
        --entrypoint sh ${dindImage} -c \
        'mkdir -p /etc/docker && printf "%s\n" "$1" >/etc/docker/daemon.json && chown 1001:1001 /home/runner/_work &&
         exec dockerd-entrypoint.sh dockerd --config-file /etc/docker/daemon.json --host unix:///var/run/engine/docker.sock --group 123' \
        sh ${lib.escapeShellArg innerDaemonConfig} \
        >/dev/null

      # As root: the image's own entry gives the `runner` account its home and
      # waits up to 60 s for the engine, then drops to `runner`.
      docker run --rm --name "$name" --network "container:$name-engine" --user 0 \
        --cpuset-cpus "$cpus" \
        --env ACTIONS_RUNNER_INPUT_JITCONFIG --env DOCKER_HOST=unix:///var/run/engine/docker.sock \
        --volume "$name-socket:/var/run/engine" --volume "$name-work:/home/runner/_work" \
        --entrypoint /usr/local/bin/myparcelle-ci-entry ${runnerImage} job
    '';
  };

  # Env and identity are dropped only for Docker calls and job startup. No
  # root helper reads a configuration file from the CI account's home.
  asCI =
    "${lib.getExe' pkgs.util-linux "setpriv"} --reuid=${user} --regid=${user} --clear-groups "
    + "${lib.getExe' pkgs.coreutils "env"} -i ${lib.escapeShellArgs dockerEnvironment}";

  startJob = pkgs.writeShellApplication {
    name = "myparcelle-ci-start-job";
    text = ''
      exec 3<"$RUNTIME_DIRECTORY/jitconfig"
      ${lib.getExe' pkgs.coreutils "rm"} "$RUNTIME_DIRECTORY/jitconfig"
      exec ${asCI} ${lib.getExe runJob} "$@" <&3 3<&-
    '';
  };

  verifyCleanup = pkgs.writeShellApplication {
    name = "myparcelle-ci-verify-cleanup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      if timeout --kill-after=5s 45s ${asCI} ${lib.getExe removeJob} "$1"; then
        exit 0
      fi
      logger -p daemon.crit -t myparcelle-ci "ci-01 slot $1 quarantined: failed to verify container and volume cleanup; see runner unit journal"
      exit 1
    '';
  };

  reserveSlot = pkgs.writeShellApplication {
    name = "myparcelle-ci-reserve-slot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      # Reserve the on-disk directory entry before job state can exist. An
      # out-of-space failure during teardown then cannot lose quarantine.
      if ! touch "$STATE_DIRECTORY/lease" || ! sync "$STATE_DIRECTORY"; then
        logger -p daemon.crit -t myparcelle-ci "ci-01 slot $1 refused startup: could not persist the cleanup lease"
        exit 1
      fi
      ${lib.getExe verifyCleanup} "$1"
      # Stop must not clear the lease if the pre-start cleanup failed.
      touch "$RUNTIME_DIRECTORY/release-allowed"
    '';
  };

  stopJob = pkgs.writeShellApplication {
    name = "myparcelle-ci-stop-job";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      [[ -e $RUNTIME_DIRECTORY/release-allowed ]] || exit 0
      trap '${lib.getExe forgetRunner}' EXIT
      ${lib.getExe verifyCleanup} "$@"
      rm "$STATE_DIRECTORY/lease"
    '';
  };

  prepare = pkgs.writeShellApplication {
    name = "myparcelle-ci-prepare";
    runtimeInputs = [
      docker
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      network=$1
      for _ in $(seq 60); do
        [[ -S ${runtimeDir}/docker.sock ]] && break
        sleep 1
      done
      docker network inspect "$network" >/dev/null 2>&1 || docker network create --ipv6=false "$network" >/dev/null
      # Serialize cold image pulls across slots. Each slot restarts on error,
      # rather than depending on a shared oneshot that can fail at boot.
      exec 9>${runtimeDir}/myparcelle-ci-image.lock
      flock 9
      for image in ${runnerImage} ${dindImage}; do
        docker image inspect "$image" >/dev/null 2>&1 || docker pull --quiet "$image" >/dev/null
      done
    '';
  };
  dockerUnit = "user@${toString uid}.service";
in
{
  assertions = [
    {
      assertion = reported == "/no-such-path" || reported == tokenFile;
      message = "myparcelle-ci-ci-01 expects ${tokenFile}, but sops-nix places it at ${reported}";
    }
  ];

  # Per machine and prompted, never shared or minted: GitHub issues the token.
  clan.core.vars.generators.myparcelle-ci-github-token = {
    prompts."token" = {
      description = "the GitHub token that mints ci-01's runner registrations (fine-grained, tyrode-dev/myParcelle only, Administration: write)";
      type = "hidden";
    };

    files."token" = {
      secret = true;
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # One line of the token alphabet; a header, a JSON envelope or an empty
    # paste is refused without being quoted.
    script = ''
      token=$(tr -d '\n' <"$prompts/token")
      [[ "$token" =~ ^[A-Za-z0-9_]{20,}$ ]] ||
        { echo "myparcelle-ci-github-token: token is not a GitHub token" >&2; exit 1; }
      printf '%s\n' "$token" >"$out/token"
    '';
  };

  # Egress of everything the CI account's engine does for a job (the rootless
  # engine's own userspace networking emits it as this uid) is public
  # internet only: private ranges, carrier-grade NAT, link-local (the
  # hosting metadata endpoint included) and their IPv6 equivalents are
  # refused, and so is the machine's own public address (no route to its sshd
  # from a job). Loopback is left alone: the engine's resolver may be there, and
  # the rootless engine already hides the host's loopback from containers.
  networking.nftables = {
    enable = true;
    tables.myparcelle-ci-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid ${toString uid} ip daddr { ${
            lib.concatStringsSep ", " (machineAddress.blockedJobIPv4 ++ [ machineAddress.ipv4 ])
          } } counter reject
          meta skuid ${toString uid} ip6 daddr { ${
            lib.concatStringsSep ", " (machineAddress.blockedJobIPv6 ++ [ machineAddress.ipv6 ])
          } } counter reject
        }
      '';
    };
  };

  users = {
    groups.${user}.gid = uid;
    users.${user} = {
      inherit uid home;
      group = user;
      isSystemUser = true;
      createHome = true;
      homeMode = "700";
      # A user manager for the account's rootless Docker engine, with no login.
      linger = true;
      subUidRanges = [
        {
          startUid = 200000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 200000;
          count = 65536;
        }
      ];
    };
  };

  systemd = {
    # The whole CI account (its engine and every job in it) is held under
    # this, whatever the per-job limits add up to.
    slices."user-${toString uid}" = {
      overrideStrategy = "asDropin";
      sliceConfig = {
        MemoryHigh = "28G";
        MemoryMax = "29G";
        CPUQuota = "1100%";
        CPUWeight = 50;
      };
    };

    services = {
      # Rootless Docker applies --cpuset-cpus only to controllers its user
      # manager was delegated.
      "user@${toString uid}" = {
        overrideStrategy = "asDropin";
        serviceConfig.Delegate = "cpu cpuset io memory pids";
      };
    }
    // lib.listToAttrs (
      map (
        slot:
        lib.nameValuePair "myparcelle-ci-runner-${toString slot}" {
          description = "myParcelle CI runner ci-01-${toString slot} (one job, then re-registers)";
          after = [
            "network-online.target"
            "nftables.service"
            dockerUnit
          ];
          wants = [ "network-online.target" ];
          requires = [
            dockerUnit
            "nftables.service"
          ];
          wantedBy = [ "multi-user.target" ];
          # An unverified teardown leaves the durable lease in place. The
          # operator checks job state before releasing the slot again.
          unitConfig.ConditionPathExists = "!/var/lib/myparcelle-ci-slot-${toString slot}/lease";
          # Waiting for the token, or for GitHub, retries forever.
          startLimitIntervalSec = 0;
          serviceConfig = {
            Environment = [ "HOME=/root" ];
            RuntimeDirectory = "myparcelle-ci-runner-${toString slot}";
            RuntimeDirectoryMode = "0700";
            StateDirectory = "myparcelle-ci-slot-${toString slot}";
            StateDirectoryMode = "0700";
            ExecStartPre = [
              "${asCI} ${lib.getExe prepare} ${slotNetwork slot}"
              "${lib.getExe reserveSlot} ${toString slot}"
              "${lib.getExe mintRunner} ${toString slot} ${lib.escapeShellArg (builtins.toJSON (slotOf slot).labels)}"
            ];
            ExecStart = "${lib.getExe startJob} ${toString slot} ${(slotOf slot).cpus} ${(slotOf slot).engine} ${slotNetwork slot}";
            ExecStopPost = "${lib.getExe stopJob} ${toString slot}";
            Restart = "always";
            RestartSec = 5;
            TimeoutStartSec = "20min";
            # A job's own ceiling is the workflow's timeout-minutes.
            TimeoutStopSec = 90;
            # Not ProtectHome: it would hide /run/user, the engine's socket.
            PrivateTmp = true;
            NoNewPrivileges = true;
          };
        }
      ) slotNumbers
    );
  };
}
