{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.atyrode.agentTools;
  rgcfg = cfg.resourceGuard;
  managedSkills = pkgs.symlinkJoin {
    name = "atyrode-agent-skills";
    paths = [ ../agents/skills ];
  };
  defaultsConfig = ../../../pkgs/omp-configured/config/defaults.yml;
  policyConfig = ../../../pkgs/omp-configured/config/policy.yml;
  untrustedConfig = ../../../pkgs/omp-configured/config/untrusted.yml;

  # Trusted sessions share one credential pool in OMP's default profile.
  #
  # One broker serves the fleet and every other machine tunnels to it. Which
  # is which, and where the tunnel goes, are decided in Nix by
  # modules/shared/omp-auth-broker.nix from fleet/auth-broker.json and arrive
  # here as the authBroker options: nothing is read from a file at run time to
  # choose. The bearer token is a shared clan var, placed by sops-nix and
  # linked to ~/.omp/auth-broker.token, where OMP reads it on both sides; the
  # broker therefore never mints one, and a broker host whose token is not yet
  # placed refuses to serve rather than inventing a token no client holds.
  bcfg = cfg.authBroker;
  brokerBind = "127.0.0.1:46171";
  rawOmpPackage = cfg.ompPackage.rawOmp or pkgs.omp;
  rawOmp = lib.getExe rawOmpPackage;
  brokerSupervisor = pkgs.writeShellScript "omp-auth-broker" (
    if bcfg.role == "serve" then
      ''
        set -euo pipefail
        token_file=${lib.escapeShellArg bcfg.tokenFile}
        if [[ ! -s "$token_file" ]]; then
          echo "omp auth broker: no bearer token at $token_file; generate it on an operator device (clan vars generate <this machine>), then atyrode apply" >&2
          exit 1
        fi
        exec ${rawOmp} --profile default auth-broker serve --bind=${brokerBind}
      ''
    else
      ''
        exec ${lib.getExe pkgs.openssh} \
          -NT \
          -L ${brokerBind}:127.0.0.1:46171 \
          -o ExitOnForwardFailure=yes \
          -o ServerAliveInterval=30 \
          -o ServerAliveCountMax=3 \
          ${lib.escapeShellArg bcfg.target}
      ''
  );

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

  # The one document that marks this machine as part of the archive fleet.
  # On a clan machine it is a link to the storage document sops-nix places
  # from the babel-archive var (modules/shared/babel-archive.nix), dangling
  # until that var is generated; nothing else writes it. That is what makes
  # it usable as the gate for everything downstream: the push wrapper below
  # refuses without it, and the hourly timer does not arm without it. The
  # wrapper resolves the same path at run time from XDG_CONFIG_HOME rather
  # than baking this one in, because it is also a command an operator runs by
  # hand and it has to mean the invoking shell's configuration directory.
  babelStorageDocument = "${config.xdg.configHome}/babel/storage.json";

  # Hourly archive of this machine's agent session history through Babel
  # (atyrode/babel SPEC.md 6.2). Babel replaced an rclone-crypt copy of the
  # same trees: it archives them with restic under a stable host identity and
  # catalogues each session in a shared PostgreSQL, so the result is
  # verifiable and selectively restorable instead of a mirrored directory.
  #
  # Babel discovers the source roots itself from its own configuration, so
  # this wrapper deliberately names no transcript paths. It exists to
  # distinguish three states that a bare `babel archive push` would blur:
  #
  #   no storage.json  this machine is not part of the archive fleet. One
  #                    line to stderr and exit 0: an unconfigured machine is
  #                    a no-op, never an hourly unit failure.
  #   push fails       loud and nonzero. The common cause is a repository
  #                    that was never created, and that MUST stay visible:
  #                    `babel archive init` is a deliberate one-time operator
  #                    act (babel SPEC.md decision 49), never a side effect
  #                    of a timer, because concurrent creation corrupts a
  #                    fresh repository and a mistyped locator would silently
  #                    become a second, empty archive.
  #   push succeeds    stamp the time so `atyrode apply` can report archive
  #                    freshness without reaching the network.
  #
  # restic is a runtime input rather than an assumed PATH entry: the profile
  # installs it for interactive use, but a user unit's environment is not the
  # login shell's, and a timer that fails at 02:00 for a missing binary is a
  # bad way to learn that.
  babelArchivePush = pkgs.writeShellApplication {
    name = "babel-archive-push";
    runtimeInputs = [
      pkgs.babel
      pkgs.restic
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      config_file="''${XDG_CONFIG_HOME:-$HOME/.config}/babel/storage.json"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/babel"

      if [[ ! -f "$config_file" ]]; then
        echo "babel-archive-push: not configured; run 'atyrode apply' to set this machine up" >&2
        exit 0
      fi

      # --json because the stamp has to be earned rather than assumed. A push
      # legitimately succeeds having archived nothing (a machine that runs no
      # harness yet, or whose source roots moved), and it fails having
      # archived only part of the tree. Neither is a fresh archive, and a
      # stamp that cannot tell the difference reports health that does not
      # exist.
      push_status=0
      result="$(babel archive push --json)" || push_status=$?

      if (( push_status != 0 )); then
        # Babel has already named the reason on stderr and the journal keeps
        # it. The common one is a repository that was never created:
        # `babel archive init` is a deliberate one-time operator act, never a
        # side effect of this timer.
        echo "babel-archive-push: push failed (exit $push_status); not recording a successful archive" >&2
        exit "$push_status"
      fi

      snapshot="$(jq -r '.snapshot_id // ""' <<<"$result")"
      incomplete="$(jq -r '.incomplete // false' <<<"$result")"
      sessions="$(jq -r '.sessions_published // 0' <<<"$result")"

      if [[ -z "$snapshot" ]]; then
        echo "babel-archive-push: no snapshot created; nothing on this host to archive" >&2
        exit 0
      fi

      if [[ "$incomplete" != false ]]; then
        echo "babel-archive-push: snapshot $snapshot is incomplete; not recording a successful archive" >&2
        exit 1
      fi

      echo "babel-archive-push: snapshot $snapshot, $sessions session(s) published" >&2

      umask 077
      mkdir -p "$state_dir"
      stamp_tmp="$(mktemp "$state_dir/.last-success.XXXXXX")"
      date -u +%FT%TZ >"$stamp_tmp"
      mv -f "$stamp_tmp" "$state_dir/last-success"
    '';
    meta.description = "Hourly Babel archive push of this machine's agent session history";
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

    ompPackage = lib.mkPackageOption pkgs "omp-configured" { };
    ompAgentsPackage = lib.mkPackageOption pkgs "omp-agents" { };
    seedPackage = lib.mkPackageOption pkgs "omp-seed" { };

    authBroker = {
      # Set by modules/shared/omp-auth-broker.nix on every clan machine. A
      # home that is not a clan machine (a portable profile, a check fixture)
      # has no role and runs no broker service: it holds no token to serve
      # with, and a tunnel to a broker it cannot authenticate to is noise.
      role = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "serve"
            "tunnel"
          ]
        );
        default = null;
        description = ''
          What this machine's broker service does: `serve` runs the fleet's
          one OMP auth broker on loopback; `tunnel` keeps an SSH local-forward
          to the machine that does. `null` runs nothing.
        '';
      };

      target = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "alex@dev-01.example.org";
        description = "SSH `user@host` the tunnel forwards to; required when role is `tunnel`.";
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Where sops-nix places the shared bearer token. The broker refuses to
          serve while it is absent, so that it never mints a token of its own.
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

        home.activation = lib.mkIf cfg.seedPlainConfig {
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
        };
      }

      (lib.mkIf (bcfg.role != null) {
        assertions = [
          {
            assertion = bcfg.role != "tunnel" || bcfg.target != null;
            message = "atyrode.agentTools.authBroker.role is tunnel, but no target is set";
          }
          {
            assertion = bcfg.role != "serve" || bcfg.tokenFile != null;
            message = "atyrode.agentTools.authBroker.role is serve, but no tokenFile is set";
          }
        ];

        # A broker host whose token is not yet placed has nothing to serve
        # with; the condition keeps the unit from restarting every five
        # seconds until the value is generated, and the supervisor's own check
        # is what says so in the journal when it is started by hand.
        systemd.user.services = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          atyrode-omp-auth-brokers = {
            Unit = {
              Description =
                if bcfg.role == "serve" then
                  "OMP authentication broker"
                else
                  "SSH tunnel to the OMP authentication broker on ${bcfg.target}";
              After = [ "network.target" ];
            }
            // lib.optionalAttrs (bcfg.role == "serve") { ConditionPathExists = bcfg.tokenFile; };
            Service = {
              Type = "simple";
              ExecStart = "${brokerSupervisor}";
              Restart = "on-failure";
              RestartSec = 5;
            };
            Install.WantedBy = [ "default.target" ];
          };
        };

        launchd.agents = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
          atyrode-omp-auth-brokers = {
            enable = true;
            config = {
              ProgramArguments = [ "${brokerSupervisor}" ];
              RunAtLoad = true;
              # PathState is launchd's ConditionPathExists: the broker is kept
              # alive only while its token is placed.
              KeepAlive = if bcfg.role == "serve" then { PathState.${bcfg.tokenFile} = true; } else true;
              ProcessType = "Background";
            };
          };
        };
      })

      {
        # The wrapper by name so an operator can run one archive by hand.
        # Babel itself comes from the agent-tools profile; rclone is gone with
        # the legacy crypt archive, whose objects were the only thing it was
        # kept on PATH to browse. restic is the recovery tool now, and Babel
        # SPEC.md 11 exercises restoring with restic alone, no Babel involved.
        home.packages = [ babelArchivePush ];

        # No Install on the service: a first archive can move multiple GB, and
        # a startup-transaction job that long holds user-manager readiness at
        # "starting". The timer triggers it instead.
        systemd.user.services.babel-archive = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          Unit = {
            Description = "Archive agent session histories with Babel";
            After = [ "network.target" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${babelArchivePush}/bin/babel-archive-push";
          };
        };

        # ConditionPathExists gates arming on the storage document having been
        # placed. Babel's SPEC.md 12 orders the rollout the other way round
        # from an unconditional timer -- storage is placed and verified first,
        # and only then does anything start pushing on a schedule, which
        # SPEC.md 14 gate 728 restates as "timer enablement only after
        # shared-storage health passes". A timer armed before that is kept
        # from publishing into an unconfigured archive only by the push
        # failing, and a guarantee made of a failure is no guarantee.
        #
        # The condition is the mechanism modules/home/profiles/manifold-node.nix
        # already uses for an unenrolled machine: systemd leaves the unit
        # inactive and records the unmet path in the journal instead of failing
        # it, so an operator asking why nothing archives gets an answer naming
        # the missing document. Because the condition is evaluated when the
        # timer starts rather than continuously, and the unit does not change
        # when the document appears, `atyrode apply` starts the timer after
        # every activation -- a machine whose document was placed today must
        # not have to wait for its next login.
        #
        # launchd has no equivalent condition, so on macOS the wrapper's own
        # check of the same document is the gate.
        #
        # Persistent: a machine that was asleep or off at the top of the hour
        # runs the missed archive once it is back, rather than silently
        # skipping a window of session history.
        systemd.user.timers.babel-archive = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
          Unit = {
            Description = "Hourly Babel archive of agent session histories";
            ConditionPathExists = babelStorageDocument;
          };
          Timer = {
            OnCalendar = "hourly";
            RandomizedDelaySec = "10m";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };

        launchd.agents.babel-archive = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
          enable = true;
          config = {
            ProgramArguments = [ "${babelArchivePush}/bin/babel-archive-push" ];
            StartInterval = 3600;
            RunAtLoad = true;
            ProcessType = "Background";
          };
        };
      }

      {
        # Ollama remains a general local-model backend and playground.
        # Operators pull models explicitly; enabling the daemon downloads none.
        services.ollama = {
          enable = lib.mkDefault true;
          port = lib.mkDefault 11434;
          environmentVariables.OLLAMA_KEEP_ALIVE = lib.mkDefault "5m";
        };
      }

      (lib.mkIf (rgcfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
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

      (lib.mkIf (rgcfg.enable && rgcfg.earlyoom.enable && pkgs.stdenv.hostPlatform.isLinux) {
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
