{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.atyrode.agentTools;
  lcfg = cfg.localClassifier;
  managedSkills = pkgs.symlinkJoin {
    name = "atyrode-agent-skills";
    paths = [
      ../../agents/skills
    ]
    ++ lib.optional (builtins.elem "desktop" config.atyrode.capabilities.selected) ../../agents/desktop-skills;
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

  # Vault definitions are machine-local. The repository ships only a generic
  # supervisor that validates the local manifest and reconciles broker children
  # whenever an atomic manifest replacement changes its content.
  vaultManifest = "${config.xdg.configHome}/code/auth-vaults.json";
  rawOmpPackage = cfg.ompPackage.rawOmp or pkgs.omp;
  rawOmp = lib.getExe rawOmpPackage;
  brokerSupervisor = pkgs.writeShellScript "omp-auth-brokers" ''
    set -euo pipefail
    umask 077

    manifest=${lib.escapeShellArg vaultManifest}
    jq=${lib.getExe pkgs.jq}
    sha256sum=${lib.getExe' pkgs.coreutils "sha256sum"}
    dirname=${lib.getExe' pkgs.coreutils "dirname"}
    mkdir=${lib.getExe' pkgs.coreutils "mkdir"}
    mktemp=${lib.getExe' pkgs.coreutils "mktemp"}
    chmod=${lib.getExe' pkgs.coreutils "chmod"}
    mv=${lib.getExe' pkgs.coreutils "mv"}

    validate_manifest() {
      "$jq" -er '
        if type != "array" or length == 0 then
          error("vault manifest must be a non-empty array")
        elif
          length != ([.[].id] | unique | length) or
          length != ([.[].profile] | unique | length) or
          length != ([.[].brokerUrl] | unique | length) or
          length != ([.[].tokenFile] | unique | length) or
          length != ([.[].snapshotCache] | unique | length)
        then
          error("vault ids, profiles, broker URLs, and runtime paths must be unique")
        elif all(.[];
          (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$") and (endswith(".") | not)) and
          (.label | type == "string" and length > 0) and
          (.profile | type == "string" and test("^[A-Za-z0-9._-]+$")) and
          (.brokerUrl | type == "string" and
            test("^http://127[.]0[.]0[.]1:[0-9]+$") and
            (split(":")[-1] | tonumber) >= 1 and
            (split(":")[-1] | tonumber) <= 65535) and
          (.tokenFile | type == "string" and startswith("/")) and
          (.snapshotCache | type == "string" and startswith("/"))
        ) then
          .[] | [.id, .profile, .brokerUrl, .tokenFile] | @tsv
        else
          error("vault entries contain unsafe or missing runtime fields")
        end
      ' "$manifest"
    }

    if [[ ! -r "$manifest" ]]; then
      echo "OMP auth vault manifest not found: $manifest" >&2
      exit 1
    fi
    entries="$(validate_manifest)"
    observed_hash="$("$sha256sum" "$manifest")"
    running_hash="$observed_hash"

    pids=()
    cleanup() {
      for pid in "''${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
      done
      wait "''${pids[@]}" 2>/dev/null || true
      pids=()
    }
    trap cleanup EXIT
    trap 'exit 0' INT TERM

    launch_entries() {
      local next_entries="$1"
      while IFS=$'\t' read -r id profile broker_url token_file; do
        bind="''${broker_url#http://}"
        state_dir="$("$dirname" "$token_file")"
        "$mkdir" -p -m 0700 "$state_dir"
        token="$(${rawOmp} --profile "$profile" auth-broker token)"
        if [[ -z "$token" ]]; then
          echo "omp auth-broker returned an empty token for vault $id" >&2
          return 1
        fi
        token_tmp="$("$mktemp" "$state_dir/.token.XXXXXX")"
        printf '%s\n' "$token" > "$token_tmp"
        "$chmod" 0600 "$token_tmp"
        "$mv" -f "$token_tmp" "$token_file"
        ${rawOmp} --profile "$profile" auth-broker serve --bind="$bind" &
        pids+=("$!")
      done <<< "$next_entries"
    }

    launch_entries "$entries"
    while true; do
      sleep 2
      if [[ -r "$manifest" ]]; then
        next_hash="$("$sha256sum" "$manifest")"
        if [[ "$next_hash" != "$observed_hash" ]]; then
          observed_hash="$next_hash"
          if next_entries="$(validate_manifest)"; then
            if [[ "$next_hash" != "$running_hash" ]]; then
              cleanup
              entries="$next_entries"
              launch_entries "$entries"
              running_hash="$next_hash"
            fi
          else
            echo "warning: invalid OMP auth vault manifest; keeping current brokers" >&2
          fi
        fi
      fi
      for pid in "''${pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
          wait "$pid"
          exit $?
        fi
      done
    done
  '';

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
              Description = "Machine-local OMP authentication brokers";
              After = [ "network.target" ];
              # The vault manifest is machine-local and never shipped by the
              # repository, so on a fresh machine its absence is an expected
              # state, not a failure. Without this condition the supervisor
              # exits 1 and Restart=on-failure thrashes into start-limit-hit,
              # leaving every fresh session degraded. After provisioning the
              # manifest, `systemctl --user restart atyrode-omp-auth-brokers`
              # (or the next login) starts the brokers.
              ConditionPathExists = vaultManifest;
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
              # Parity with the Linux ConditionPathExists: only respawn the
              # supervisor while the machine-local manifest exists; launchd
              # additionally launches it when the manifest first appears.
              KeepAlive.PathState.${vaultManifest} = true;
              ProcessType = "Background";
            };
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
    ]
  );
}
