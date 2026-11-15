# Self-hosted GitHub Actions runners for myParcelle's CI (myParcelle's
# docs/workflows/DELIVERY.md § Self-hosted runners), on dev-01.
#
# The runners execute pull-request code, so nothing of the operator's reaches
# them:
#
#   user       `myparcelle-ci`, a system account with its own home under
#              /var/lib and its own rootless Docker engine; no wheel, no
#              docker group, no SSH login, no access to /home.
#   isolation  every job runs in a fresh pair of containers in that engine: a
#              Docker-in-Docker daemon (the job's own engine, for `services:`,
#              buildx and compose) and the upstream actions/runner image
#              sharing its network namespace, so every job has its own
#              loopback and ports. Both are deleted with their volumes when
#              the job ends; the next job starts from the images again.
#   ephemeral  each start mints a just-in-time runner configuration: one
#              runner, one job, then it de-registers and the unit restarts.
#   credential the long-lived GitHub token that mints those configurations is
#              a root-only file the operator places (a fine-grained token on
#              the one repository, Administration: write). Only root's
#              ExecStartPre reads it; the CI account receives the single-use
#              runner configuration and nothing else.
#   limits     each job's containers are capped (CPU, memory), and the CI
#              account's whole slice is capped below what dev, Keycloak and
#              the agents need.
#
# Docker Hub limits anonymous pulls per address, and every job's engine starts
# empty, so a pull-through mirror of Docker Hub serves the jobs' images.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "myparcelle-ci";
  uid = 940;
  home = "/var/lib/${user}";
  runtimeDir = "/run/user/${toString uid}";
  dockerHost = "unix://${runtimeDir}/docker.sock";
  docker = config.virtualisation.docker.rootless.package;

  repository = "tyrode-dev/myParcelle";
  runnerCount = 3;
  labels = [
    "self-hosted"
    "linux"
    "x64"
    "dev-01"
  ];
  # Root-only; the operator places it, nothing in this repository holds it.
  tokenDirectory = "/var/lib/myparcelle-ci-runners";
  tokenFile = "${tokenDirectory}/github-token";

  network = "myparcelle-ci";
  mirrorName = "myparcelle-ci-mirror";

  runnerBase = "ghcr.io/actions/actions-runner:2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300";
  composeBin = "docker/compose-bin:v2.40.3@sha256:e39da8206cc48c6e2c99ce371935eef9d7eff7db600a993fd357de8b75621edf";
  dindImage = "docker:28.5.2-dind@sha256:2a232a42256f70d78e3cc5d2b5d6b3276710a0de0596c145f627ecfae90282ac";
  mirrorImage = "registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e";

  # The upstream runner image plus what GitHub's hosted Ubuntu image gives the
  # workflows and the runner image lacks: Compose, gh, Node on PATH, and the
  # Chromium libraries Playwright installs (pre-installed so a job's
  # `install-deps` finds them present).
  dockerfile = pkgs.writeText "myparcelle-ci-runner.Dockerfile" ''
    FROM ${runnerBase}
    USER root
    COPY --from=${composeBin} /docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
    RUN apt-get update \
     && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
          gh xz-utils zstd openssh-client \
     && ln -s /home/runner/externals/node24/bin/node /usr/local/bin/node \
     && ln -s /home/runner/externals/node24/bin/npm /usr/local/bin/npm \
     && ln -s /home/runner/externals/node24/bin/npx /usr/local/bin/npx \
     && npx --yes playwright@1.60.0 install-deps chromium \
     && rm -rf /var/lib/apt/lists/* /root/.npm \
     && install -d -o runner -g runner /home/runner/_work
    USER runner
  '';
  runnerImage = "localhost/myparcelle-ci-runner:${builtins.substring 0 12 (baseNameOf dockerfile)}";

  # Job budget: GitHub's hosted runner for private repositories is 2 vCPU,
  # 7 GB. The runner container holds the job's own processes (Bun, Vite,
  # Chromium); the engine holds its services (PostgreSQL, Keycloak, buildx).
  runnerLimits = [
    "--cpus=2"
    "--memory=3584m"
    "--memory-swap=3584m"
  ];
  engineLimits = [
    "--cpus=2"
    "--memory=2g"
    "--memory-swap=2g"
  ];

  dockerEnvironment = [
    "DOCKER_HOST=${dockerHost}"
    "XDG_RUNTIME_DIR=${runtimeDir}"
    "HOME=${home}"
  ];

  # Root: reads the operator's token and leaves one runner's configuration,
  # readable by the CI account only, in the unit's runtime directory. The
  # token reaches curl on stdin, never argv or the environment.
  mintRunner = pkgs.writeShellApplication {
    name = "myparcelle-ci-mint-runner";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      slot=$1
      [[ -s ${tokenFile} ]] || {
        echo "myparcelle-ci: ${tokenFile} is not placed; the runner waits for it" >&2
        exit 1
      }
      body=$(jq -cn --arg name "dev-01-$slot-$(date +%s)" --argjson labels ${lib.escapeShellArg (builtins.toJSON labels)} \
        '{name: $name, runner_group_id: 1, labels: $labels, work_folder: "_work"}')
      umask 077
      response=$(printf 'Authorization: Bearer %s\n' "$(<${tokenFile})" |
        curl --silent --show-error --fail-with-body --max-time 30 -H @- \
          -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
          --data "$body" https://api.github.com/repos/${repository}/actions/runners/generate-jitconfig)
      jq -er .encoded_jit_config <<<"$response" >"$RUNTIME_DIRECTORY/jitconfig"
      jq -er .runner.id <<<"$response" >"$RUNTIME_DIRECTORY/runner-id"
      chown ${user}: "$RUNTIME_DIRECTORY/jitconfig"
    '';
  };

  # Root, after the unit stops: a runner minted but never connected (the unit
  # stopped or failed before its job) is removed rather than left offline.
  # A runner that ran its job is already gone, and the 404 is expected.
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
        curl --silent --output /dev/null --max-time 30 -H @- -X DELETE \
          -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
          "https://api.github.com/repos/${repository}/actions/runners/$id" || true
    '';
  };

  removeJob = pkgs.writeShellApplication {
    name = "myparcelle-ci-remove-job";
    runtimeInputs = [ docker ];
    text = ''
      name=myparcelle-ci-runner-$1
      docker rm --force --volumes "$name" "$name-engine" >/dev/null 2>&1 || true
      docker volume rm --force "$name-work" "$name-socket" >/dev/null 2>&1 || true
    '';
  };

  # The CI account: one job in fresh containers, then exit; systemd restarts
  # the unit, which mints the next runner.
  runJob = pkgs.writeShellApplication {
    name = "myparcelle-ci-run-job";
    runtimeInputs = [
      docker
      pkgs.coreutils
      removeJob
    ];
    text = ''
      slot=$1
      name=myparcelle-ci-runner-$slot
      ACTIONS_RUNNER_INPUT_JITCONFIG=$(<"$RUNTIME_DIRECTORY/jitconfig")
      export ACTIONS_RUNNER_INPUT_JITCONFIG
      rm -f "$RUNTIME_DIRECTORY/jitconfig"
      myparcelle-ci-remove-job "$slot"
      trap 'myparcelle-ci-remove-job "$slot"' EXIT

      # The job's engine. Its socket and the job's workspace are volumes both
      # containers mount at the same paths, so bind mounts a job asks the
      # engine for (compose files, build contexts) resolve to the same files.
      docker run --detach --rm --privileged --name "$name-engine" --network ${network} \
        ${lib.escapeShellArgs engineLimits} \
        --env DOCKER_TLS_CERTDIR= \
        --volume "$name-socket:/var/run/engine" --volume "$name-work:/home/runner/_work" \
        --entrypoint sh ${dindImage} -c \
        'chown 1001:1001 /home/runner/_work && exec dockerd-entrypoint.sh dockerd --host unix:///var/run/engine/docker.sock --group 123 --registry-mirror http://${mirrorName}:5000' \
        >/dev/null

      docker run --rm --name "$name" --network "container:$name-engine" \
        ${lib.escapeShellArgs runnerLimits} \
        --env ACTIONS_RUNNER_INPUT_JITCONFIG --env DOCKER_HOST=unix:///var/run/engine/docker.sock \
        --volume "$name-socket:/var/run/engine" --volume "$name-work:/home/runner/_work" \
        --entrypoint bash ${runnerImage} -c \
        'for _ in $(seq 60); do docker version >/dev/null 2>&1 && exec /home/runner/run.sh; sleep 1; done; echo "the job engine did not start" >&2; exit 1'
    '';
  };

  prepare = pkgs.writeShellApplication {
    name = "myparcelle-ci-prepare";
    runtimeInputs = [ docker ];
    text = ''
      docker network inspect ${network} >/dev/null 2>&1 || docker network create ${network} >/dev/null
      docker image inspect ${runnerImage} >/dev/null 2>&1 ||
        docker build --pull --tag ${runnerImage} - <${dockerfile}
    '';
  };

  dockerUnit = "user@${toString uid}.service";
in
{
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
    tmpfiles.rules = [ "d ${tokenDirectory} 0700 root root - -" ];

    # The whole CI account (its engine and every job in it) is held under
    # this, whatever the per-job limits add up to: dev (5 GB), Keycloak
    # (1.5 GB) and the agents keep the rest of the machine.
    slices."user-${toString uid}" = {
      overrideStrategy = "asDropin";
      sliceConfig = {
        MemoryHigh = "10G";
        MemoryMax = "11G";
        CPUQuota = "700%";
        CPUWeight = 50;
      };
    };

    services = {
      myparcelle-ci-prepare = {
        description = "myParcelle CI runner image and network";
        after = [ dockerUnit ];
        requires = [ dockerUnit ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = user;
          Group = user;
          Environment = dockerEnvironment;
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for _ in $(seq 60); do [ -S ${runtimeDir}/docker.sock ] && exit 0; sleep 1; done; exit 1'";
          ExecStart = lib.getExe prepare;
          TimeoutStartSec = "20min";
        };
      };

      myparcelle-ci-mirror = {
        description = "Docker Hub pull-through mirror for myParcelle CI jobs";
        after = [ "myparcelle-ci-prepare.service" ];
        requires = [ "myparcelle-ci-prepare.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = user;
          Group = user;
          Environment = dockerEnvironment;
          ExecStartPre = "-${lib.getExe docker} rm --force ${mirrorName}";
          ExecStart = lib.concatStringsSep " " [
            "${lib.getExe docker} run --rm --name ${mirrorName} --network ${network}"
            "--memory=256m --env REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io"
            "--volume ${mirrorName}:/var/lib/registry ${mirrorImage}"
          ];
          ExecStop = "${lib.getExe docker} stop ${mirrorName}";
          Restart = "always";
          RestartSec = 10;
        };
      };
    }
    // lib.listToAttrs (
      map (
        slot:
        lib.nameValuePair "myparcelle-ci-runner-${toString slot}" {
          description = "myParcelle CI runner ${toString slot} (one job, then re-registers)";
          after = [
            "network-online.target"
            "myparcelle-ci-prepare.service"
            "myparcelle-ci-mirror.service"
          ];
          wants = [
            "network-online.target"
            "myparcelle-ci-mirror.service"
          ];
          requires = [ "myparcelle-ci-prepare.service" ];
          wantedBy = [ "multi-user.target" ];
          # Waiting for the token file, or for GitHub, retries forever.
          startLimitIntervalSec = 0;
          serviceConfig = {
            User = user;
            Group = user;
            Environment = dockerEnvironment;
            RuntimeDirectory = "myparcelle-ci-runner-${toString slot}";
            RuntimeDirectoryMode = "0700";
            ExecStartPre = "+${lib.getExe mintRunner} ${toString slot}";
            ExecStart = "${lib.getExe runJob} ${toString slot}";
            ExecStopPost = [
              "${lib.getExe removeJob} ${toString slot}"
              "+${lib.getExe forgetRunner}"
            ];
            Restart = "always";
            RestartSec = 5;
            # A job's own ceiling is the workflow's timeout-minutes.
            TimeoutStopSec = 90;
            # Not ProtectHome: it would hide /run/user, the engine's socket.
            # /home/alex is mode 700 to this account in any case.
            PrivateTmp = true;
            NoNewPrivileges = true;
          };
        }
      ) (lib.range 1 runnerCount)
    );
  };
}
