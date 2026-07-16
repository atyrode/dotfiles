{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.atyrode.agentTools;
  lcfg = cfg.localClassifier;
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
  vaultManifest = "${config.xdg.configHome}/atyrode/code-auth-vaults.json";
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

    migrateLegacy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Back up conflicting legacy agent-tool paths before Home Manager links managed files.";
    };

    seedPlainConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Seed the curated plain-omp defaults into the writable machine
        configuration with drift reporting. Local edits always win.
      '';
    };

    ompPackage = lib.mkPackageOption pkgs "omp-configured" { };
    ompAgentsPackage = lib.mkPackageOption pkgs "omp-agents" { };
    migrationPackage = lib.mkPackageOption pkgs "agent-tools-migrate" { };
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
          `code` requests (CODE_EVAL_MODEL / cli-kit's DefaultLocalModel).
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

        home.file = {
          ".agents/skills" = {
            source = ../../agents/skills;
            recursive = true;
          };
        };

        home.activation = lib.mkMerge [
          (lib.mkIf cfg.migrateLegacy {
            migrateLegacyAgentTools = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
              if [[ -v DRY_RUN ]]; then
                export AGENT_TOOLS_DRY_RUN=1
              fi
              ${lib.getExe cfg.migrationPackage} prepare
            '';

            finalizeLegacyAgentTools = lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" ] ''
              if [[ -v DRY_RUN ]]; then
                export AGENT_TOOLS_DRY_RUN=1
              fi
              ${lib.getExe cfg.migrationPackage} finalize "$newGenPath/home-files"
            '';
          })
          (lib.mkIf cfg.seedPlainConfig {
            # Runs after the legacy migration so a first activation seeds the
            # transformed configuration, never the pre-migration backup source.
            # Seeding is a convenience: a failure (for example unparseable
            # operator YAML) warns instead of failing the whole activation.
            seedPlainOmpConfig =
              lib.hm.dag.entryAfter
                (
                  [
                    "installPackages"
                    "linkGeneration"
                  ]
                  ++ lib.optional cfg.migrateLegacy "finalizeLegacyAgentTools"
                )
                ''
                  if [[ -v DRY_RUN ]]; then
                    export AGENT_TOOLS_DRY_RUN=1
                  fi
                  if ! ${lib.getExe cfg.seedPackage} apply; then
                    echo "warning: plain-omp seeding failed; inspect with atyrode-omp-seed status" >&2
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
            };
            Service = {
              Type = "simple";
              ExecStart = "${brokerSupervisor}";
              Restart = "on-failure";
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

      (lib.mkIf lcfg.enable {
        services.ollama = {
          enable = true;
          port = lcfg.port;
          environmentVariables.OLLAMA_KEEP_ALIVE = lcfg.keepAlive;
        };

        # Auto-pull the classifier model once the daemon is up. systemd user
        # services are Linux-only in Home Manager; on other platforms the daemon
        # still runs (via the launchd agent the ollama module defines) but the
        # model is pulled on first use / manually.
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
          Install.WantedBy = [ "default.target" ];
        };
      })
    ]
  );
}
