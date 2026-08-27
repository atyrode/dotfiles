{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.atyrode.agentTools;
  lcfg = cfg.localClassifier;
  rgcfg = cfg.resourceGuard;
  managedSkills = pkgs.symlinkJoin {
    name = "atyrode-agent-skills";
    paths = [ ../../agents/skills ];
  };
  ollamaBin = lib.getExe pkgs.ollama;
  # Pull the generator's classifier model to disk once the daemon is up (only if
  # missing — the pull is a no-op otherwise), so the first Load in the generator is a
  # fast RAM-load rather than a multi-minute download. The model is NOT loaded
  # into memory here: residency is the user's explicit choice via the generator's
  # load/unload toggle (see cli-kit Loadable), so it never occupies RAM unbidden.
  pullClassifierModel = pkgs.writeShellScript "ollama-pull-classifier" ''
    set -u
    export OLLAMA_HOST=127.0.0.1:${toString lcfg.port}
    for _ in $(seq 1 60); do
      if ${ollamaBin} list >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if ${ollamaBin} list 2>/dev/null | grep -qF ${lib.escapeShellArg lcfg.model}; then
      echo "ollama: ${lcfg.model} already present"
      exit 0
    fi
    echo "ollama: pulling ${lcfg.model} for the code generator (first run only)..."
    exec ${ollamaBin} pull ${lib.escapeShellArg lcfg.model}
  '';
  defaultsConfig = ../../omp/defaults.yml;
  policyConfig = ../../omp/policy.yml;
  untrustedConfig = ../../omp/untrusted.yml;

  # Trusted sessions share one credential pool in OMP's default profile. `code`
  # applies immutable per-launch account pools; changing a preset never mutates
  # or duplicates credentials.
  brokerStateDir = "${config.xdg.stateHome}/atyrode/omp-auth-broker";
  brokerTokenFile = "${brokerStateDir}/token";
  brokerBind = "127.0.0.1:46171";
  rawOmpPackage = cfg.ompPackage.rawOmp or pkgs.omp;
  rawOmp = lib.getExe rawOmpPackage;
  brokerSupervisor = pkgs.writeShellScript "omp-auth-broker" ''
    set -euo pipefail
    umask 077

    state_dir=${lib.escapeShellArg brokerStateDir}
    token_file=${lib.escapeShellArg brokerTokenFile}
    mkdir=${lib.getExe' pkgs.coreutils "mkdir"}
    mktemp=${lib.getExe' pkgs.coreutils "mktemp"}
    chmod=${lib.getExe' pkgs.coreutils "chmod"}
    mv=${lib.getExe' pkgs.coreutils "mv"}

    "$mkdir" -p -m 0700 "$state_dir"
    token="$(${rawOmp} --profile default auth-broker token)"
    if [[ -z "$token" ]]; then
      echo "omp auth-broker returned an empty token" >&2
      exit 1
    fi
    token_tmp="$("$mktemp" "$state_dir/.token.XXXXXX")"
    printf '%s\n' "$token" > "$token_tmp"
    "$chmod" 0600 "$token_tmp"
    "$mv" -f "$token_tmp" "$token_file"
    exec ${rawOmp} --profile default auth-broker serve --bind=${brokerBind}
  '';

  # Host-wide pressure guard: when the machine is running out of both memory
  # and swap, earlyoom kills the fattest expendable agent worker before the
  # kernel chooses a state-owning process. Runs unprivileged, which suffices
  # because the whole agent stack belongs to this user. Deliberately no
  # Nice=/OOMScoreAdjust= on the unit: upstream recommends both, but they need
  # privileges a user service does not have and would make it fail to start.
  #
  # Victim policy targets the work, not the things that own it. An `omp`
  # session holds conversation state and in-flight edits that nothing can
  # reconstruct, and the terminal and machine infrastructure around it (tmux,
  # sshd, systemd, zsh) anchors even more of it. What a session *spawns* is
  # the opposite: language servers, watchers, bundlers and headless Chrome
  # are the unbounded half, they are what actually grows, and every one of
  # them is recreated on demand. So the harness and its anchors are avoided;
  # its children preferred.
  # `MainThread` is in that list because Node renames the main thread of the
  # TypeScript servers, which are routinely the single largest processes here.
  #
  # This is a scoring preference, not immunity: earlyoom divides a process'
  # badness rather than exempting it. Negative OOMScoreAdjust would provide
  # kernel-level immunity, but requires privileges and careful child resets.
  earlyoomSupervisor = pkgs.writeShellScript "atyrode-earlyoom" ''
    exec ${pkgs.earlyoom}/bin/earlyoom \
      -m ${toString rgcfg.earlyoom.memoryPercent} \
      -s ${toString rgcfg.earlyoom.swapPercent} \
      -r 0 \
      --avoid '^(sshd|systemd|dbus-daemon|zsh|tmux.*|omp)$' \
      --prefer '^(bun|node|chrome|MainThread)$'
  '';

  # Continuous agent-session archive: append-only rclone copy of omp/codex/
  # Claude transcripts to a Cellar (S3) bucket, client-side encrypted with
  # rclone crypt. Credentials come from a machine-local env file seeded from
  # the Bitwarden vault by `atyrode backup setup`; an unconfigured machine is
  # a silent no-op here (apply/status surface it), never a unit failure.
  # `copy` (not `sync`) never deletes remote objects, so the archive is
  # append/update-only; rclone's size+modtime comparison re-uploads sessions
  # that append under an unchanged filename.
  sessionBackupSync = pkgs.writeShellApplication {
    name = "atyrode-session-backup";
    runtimeInputs = [
      pkgs.rclone
      pkgs.coreutils
    ];
    text = ''
      env_file="''${XDG_CONFIG_HOME:-$HOME/.config}/atyrode/session-backup/env"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/atyrode/session-backup"

      if [[ ! -f "$env_file" ]]; then
        echo "atyrode-session-backup: not configured; run: atyrode backup setup" >&2
        exit 0
      fi

      set -a
      # shellcheck source=/dev/null
      source "$env_file"
      set +a

      host="$(uname -n)"
      flags=(--fast-list --transfers 8 --checkers 8 --contimeout 30s --timeout 5m --retries 3 --log-level NOTICE)
      if [[ -t 2 ]]; then
        flags+=(--progress)
      fi

      # One tree failing must not block the others; report at the end.
      fail=0
      copy_tree() {
        [[ -d "$1" ]] || return 0
        rclone copy "''${flags[@]}" "$1" "archive:$host/$2" || fail=1
      }
      copy_file() {
        [[ -f "$1" ]] || return 0
        rclone copyto "''${flags[@]}" "$1" "archive:$host/$2" || fail=1
      }

      copy_tree "$HOME/.omp/agent/sessions" omp/sessions
      copy_tree "$HOME/.omp/collab" omp/collab
      copy_tree "$HOME/.codex/sessions" codex/sessions
      copy_file "$HOME/.codex/history.jsonl" codex/history.jsonl
      copy_file "$HOME/.codex/session_index.jsonl" codex/session_index.jsonl
      copy_tree "$HOME/.codex/attachments" codex/attachments
      copy_tree "$HOME/.claude/projects" claude/projects

      [[ "$fail" == 0 ]] || exit 1
      umask 077
      mkdir -p "$state_dir"
      stamp_tmp="$(mktemp "$state_dir/.last-success.XXXXXX")"
      date -u +%FT%TZ >"$stamp_tmp"
      mv -f "$stamp_tmp" "$state_dir/last-success"
    '';
  };

in
{
  options.atyrode.agentTools = {
    enable = lib.mkEnableOption "the declarative OMP stack";

    seedPlainConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Seed the curated plain-omp defaults into the writable machine
        configuration with drift reporting. Local edits always win.
      '';
    };

    seedSpeechModels = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pre-download the omp speech stack (STT/TTS models and the sherpa
        runtime) during activation so speech is ready on first use. The
        downloads are mutable harness-owned cache state, not Nix artifacts;
        seeding is best-effort and warns instead of failing activation.
      '';
    };

    ompPackage = lib.mkPackageOption pkgs "omp-configured" { };
    ompAgentsPackage = lib.mkPackageOption pkgs "omp-agents" { };
    seedPackage = lib.mkPackageOption pkgs "omp-seed" { };

    localClassifier = {
      # A local model that powers `code`'s prompt→profile suggestion (ctrl+o): a
      # small instruct model on the ollama daemon answers over loopback with no
      # auth and no network. The daemon is a general Asker/Commander backend and a
      # local-model playground, not generator-only — hence enabled everywhere.
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run the nix-managed ollama daemon (and put the ollama CLI on PATH). On
          Linux the daemon runs as a systemd user service and the generator's
          classifier model is auto-pulled to disk on activation; on macOS the
          daemon runs via launchd and models are pulled manually (`ollama pull`).
          The model is never loaded into memory automatically — residency is the
          user's explicit choice via the generator's load/unload toggle.
        '';
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "qwen2.5:3b";
        description = ''
          The ollama model tag the generator classifies with. Must match the model
          `code` requests (CODE_EVAL_MODEL / ollama.DefaultModel in
          github.com/atyrode/cli-kit — keep the two in sync by hand).
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 11434;
        description = "Loopback port the ollama daemon listens on.";
      };

      keepAlive = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        example = "-1";
        description = ''
          The daemon's DEFAULT keep-alive (OLLAMA_KEEP_ALIVE) for requests that do
          not set their own — i.e. manual `ollama run` chats. The code generator sets
          its own per call (pinned while loaded, evict-after while not), so this
          does not affect it. "-1" would pin every model forever.
        '';
      };
    };

    resourceGuard = {
      # The agent stack (OMP sessions, their language servers, Chrome, and bun
      # workers) runs under the user manager's app.slice. Account for it there,
      # but let host-wide pressure reach earlyoom: unlike a cgroup MemoryMax
      # kill, earlyoom can preserve state-owning harness processes while
      # shedding their individually recreatable workers.
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Account for the agent stack in app.slice and run an unprivileged,
          victim-aware earlyoom guard. Linux-only: both mechanisms are systemd
          and cgroup features with no macOS equivalent.
        '';
      };

      memoryHigh = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "8G";
        description = ''
          MemoryHigh for app.slice, or null to leave it unset. This is a
          throttle, not a limit: past it the kernel forces reclaim onto the
          allocating task itself, so the thread is put to sleep rather than
          anything being killed.

          Off by default because that behaviour is wrong for this workload. An
          agent stack sits at a high, spiky steady state, so a percentage cap
          parks it permanently just above the watermark and every allocation
          pays synchronous reclaim into swap and refaults straight back out.
          Measured on a 16 GB host at 60%: 2.7 million throttle events and 46
          minutes of accumulated full stall, against zero OOM kills - the
          throttle never once protected anything, it only wedged sessions, and
          a wedged agent session is unrecoverable in a way a killed one is not.

          Removing it removes that proven harm. Host-wide earlyoom is the
          graceful fallback for the default policy: it waits for genuine
          memory-and-swap pressure, then prefers recreatable workers over the
          state-owning harness. Set MemoryHigh only for a workload whose
          allocation is smooth enough that reclaim keeps up.
        '';
      };

      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "infinity";
        example = "12G";
        description = ''
          MemoryMax for app.slice. The default deliberately leaves the hard
          ceiling disabled: a cgroup OOM kill cannot distinguish state-owning
          harness processes from recreatable workers, while earlyoom can.
          Set a finite value only when bounding the entire slice matters more
          than preserving its sessions.
        '';
      };

      earlyoom = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Run earlyoom as a user service. It can only kill this user's
            processes, which covers the entire agent stack.
          '';
        };

        memoryPercent = lib.mkOption {
          type = lib.types.ints.between 1 100;
          default = 15;
          description = ''
            Available-memory floor, in percent. earlyoom acts only once this
            and the swap floor are breached together, so it stays dormant on a
            healthy machine and fires before the swap-exhaustion pattern wedges
            the host into thrashing.
          '';
        };

        swapPercent = lib.mkOption {
          type = lib.types.ints.between 1 100;
          default = 20;
          description = "Free-swap floor, in percent. See memoryPercent.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [
          cfg.ompPackage
        ]
        ++ lib.optional cfg.seedPlainConfig cfg.seedPackage;

        xdg.configFile = {
          "omp/defaults.yml".source = defaultsConfig;
          "omp/policy.yml".source = policyConfig;
          "omp/untrusted.yml".source = untrustedConfig;
        };

        home.file.".agents/skills" = {
          source = managedSkills;
          recursive = true;
        };

        home.activation = lib.mkMerge [
          (lib.mkIf cfg.seedPlainConfig {
            # Seeding is a convenience: a failure (for example unparseable
            # operator YAML) warns instead of failing the whole activation.
            seedPlainOmpConfig =
              lib.hm.dag.entryAfter
                [
                  "installPackages"
                  "linkGeneration"
                ]
                ''
                  if [[ -v DRY_RUN ]]; then
                    export AGENT_TOOLS_DRY_RUN=1
                  fi
                  if ! ${lib.getExe cfg.seedPackage} apply; then
                    echo "warning: plain-omp seeding failed; inspect with atyrode-omp-seed status" >&2
                  fi
                '';
          })
          (lib.mkIf cfg.seedSpeechModels {
            # Speech models live in mutable harness-owned cache state
            # (~/.omp/agent/cache), so this is a seed, not a build product.
            # `--check --json` is offline and cheap; the download runs only
            # when something is missing. Non-interactive stdin makes
            # `omp setup speech` select the curated defaults (Parakeet TDT v3
            # + Kokoro-82M). rawOmp is the wrapped omp, so the sherpa addon's
            # LD_LIBRARY_PATH and the fallback ffmpeg ride along.
            seedOmpSpeechModels =
              lib.hm.dag.entryAfter
                (
                  [
                    "installPackages"
                    "linkGeneration"
                  ]
                  ++ lib.optional cfg.seedPlainConfig "seedPlainOmpConfig"
                )
                ''
                  if [[ -v DRY_RUN ]]; then
                    echo "(dry run) would seed omp speech models via 'omp setup speech'"
                  elif ! ${rawOmp} setup speech --check --json 2>/dev/null \
                    | ${lib.getExe pkgs.jq} -e '[.[].ready] | all' >/dev/null 2>&1; then
                    echo "agent-tools: seeding omp speech models (first run downloads ~700 MB)..."
                    if ! ${pkgs.coreutils}/bin/timeout 1800 ${rawOmp} setup speech </dev/null; then
                      echo "warning: omp speech seeding failed; run 'omp setup speech' manually" >&2
                    fi
                  fi
                '';
          })
        ];
      }

      {
        systemd.user.services = lib.mkIf pkgs.stdenv.isLinux {
          atyrode-omp-auth-brokers = {
            Unit = {
              Description = "Machine-local OMP authentication broker";
              After = [ "network.target" ];
            };
            Service = {
              Type = "simple";
              ExecStart = "${brokerSupervisor}";
              Restart = "on-failure";
              RestartSec = 5;
            };
            Install.WantedBy = [ "default.target" ];
          };
        };

        launchd.agents = lib.mkIf pkgs.stdenv.isDarwin {
          atyrode-omp-auth-brokers = {
            enable = true;
            config = {
              ProgramArguments = [ "${brokerSupervisor}" ];
              RunAtLoad = true;
              KeepAlive = true;
              ProcessType = "Background";
            };
          };
        };
      }

      {
        # rclone on PATH for manual browse/restore; the sync script by name so
        # `atyrode backup now` can exec it.
        home.packages = [
          pkgs.rclone
          sessionBackupSync
        ];

        # No Install on the service: the first run can move multiple GB, and a
        # startup-transaction job that long holds user-manager readiness at
        # "starting" (same rationale as ollama-pull-classifier below). The
        # timer triggers it instead.
        systemd.user.services.atyrode-session-backup = lib.mkIf pkgs.stdenv.isLinux {
          Unit = {
            Description = "Archive agent session histories to Cellar";
            After = [ "network.target" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${sessionBackupSync}/bin/atyrode-session-backup";
          };
        };

        systemd.user.timers.atyrode-session-backup = lib.mkIf pkgs.stdenv.isLinux {
          Unit.Description = "Hourly agent-session archive to Cellar";
          Timer = {
            OnCalendar = "hourly";
            RandomizedDelaySec = "10m";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };

        launchd.agents.atyrode-session-backup = lib.mkIf pkgs.stdenv.isDarwin {
          enable = true;
          config = {
            ProgramArguments = [ "${sessionBackupSync}/bin/atyrode-session-backup" ];
            StartInterval = 3600;
            RunAtLoad = true;
            ProcessType = "Background";
          };
        };
      }

      (lib.mkIf lcfg.enable {
        services.ollama = {
          enable = true;
          inherit (lcfg) port;
          environmentVariables.OLLAMA_KEEP_ALIVE = lcfg.keepAlive;
        };

        # Auto-pull the classifier model once the daemon is up. systemd user
        # services are Linux-only in Home Manager; on other platforms the daemon
        # still runs (via the launchd agent the ollama module defines) but the
        # model is pulled on first use / manually.
        #
        # The service deliberately has no Install: a first-boot multi-GB pull
        # inside the startup transaction holds `systemctl --user
        # is-system-running` at "starting" for its whole duration. The timer
        # below triggers it shortly after startup instead, outside the
        # readiness transaction.
        systemd.user.services.ollama-pull-classifier = lib.mkIf pkgs.stdenv.isLinux {
          Unit = {
            Description = "Pull the code generator's local classifier model to disk (${lcfg.model})";
            After = [ "ollama.service" ];
            Wants = [ "ollama.service" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${pullClassifierModel}";
          };
        };

        systemd.user.timers.ollama-pull-classifier = lib.mkIf pkgs.stdenv.isLinux {
          Unit.Description = "Trigger the classifier model pull after session startup";
          Timer = {
            # 30s keeps the trigger comfortably outside the startup job queue
            # (racing into it would re-gate readiness); the default minute-level
            # AccuracySec would smear that on purpose-built delay, so pin it.
            OnActiveSec = "30s";
            AccuracySec = "1s";
          };
          Install.WantedBy = [ "timers.target" ];
        };
      })

      (lib.mkIf (rgcfg.enable && pkgs.stdenv.isLinux) {
        # A drop-in rather than a systemd.user.slices unit: Home Manager would
        # write a full app.slice into ~/.config/systemd/user, which takes
        # precedence over and therefore replaces systemd's own definition. The
        # drop-in only adds the limits and leaves upstream's unit intact.
        xdg.configFile."systemd/user/app.slice.d/50-atyrode-memory.conf".text = ''
          [Slice]
          MemoryAccounting=yes
        ''
        + lib.optionalString (rgcfg.memoryHigh != null) ''
          MemoryHigh=${rgcfg.memoryHigh}
        ''
        + ''
          MemoryMax=${rgcfg.memoryMax}
        '';
      })

      (lib.mkIf (rgcfg.enable && rgcfg.earlyoom.enable && pkgs.stdenv.isLinux) {
        home.packages = [ pkgs.earlyoom ];

        systemd.user.services.atyrode-earlyoom = {
          Unit = {
            Description = "Userspace OOM killer guarding the agent stack";
          };
          Service = {
            Type = "simple";
            ExecStart = "${earlyoomSupervisor}";
            Restart = "on-failure";
            RestartSec = 5;
          };
          Install.WantedBy = [ "default.target" ];
        };
      })
    ]
  );
}
