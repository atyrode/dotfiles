{
  lib,
  pkgs,
  clanMachine,
  darwinMachine,
}:

let
  homeOf = machine: machine.home-manager.users.${lib.head (lib.attrNames machine.home-manager.users)};
  linuxHome = homeOf clanMachine;
  darwinHome = homeOf darwinMachine;
  # Only the strings are inspected: the inspected machines are dev-01 and the
  # macbook even on runners of another system, whose derivations that runner
  # cannot build.
  inspect = builtins.unsafeDiscardStringContext;
  service = linuxHome.systemd.user.services.omp-session-archive;
  execStart = lib.concatStringsSep " " (lib.toList service.Service.ExecStart);
  timer = linuxHome.systemd.user.timers.omp-session-archive;
  darwinAgent = darwinHome.launchd.agents.omp-session-archive;
  darwinHasService = darwinHome.systemd.user.services ? omp-session-archive;
  legacy = [
    "babel-archive"
    "atyrode-session-backup"
    "babel-store-backup"
  ];
  hasLegacy = lib.any (
    name:
    linuxHome.systemd.user.services ? ${name}
    || linuxHome.systemd.user.timers ? ${name}
    || darwinHome.launchd.agents ? ${name}
  ) legacy;

  # The timer is gated on the placed environment file: an unconfigured machine
  # never arms it. Read through an assertion so a removed gate fails by name.
  envFile = "${linuxHome.xdg.configHome}/omp-session-archive/restic.env";
  timerGate =
    assert lib.assertMsg (timer.Unit ? ConditionPathExists)
      "the archive timer must not arm before the environment is placed: restore ConditionPathExists on its [Unit]";
    timer.Unit.ConditionPathExists;

  generator = clanMachine.clan.core.vars.generators.omp-session-archive;
  custody = clanMachine.clan.core.vars.generators.babel-custody;
  link =
    pkgs.runCommand "check-omp-session-archive-link" { }
      linuxHome.xdg.configFile."omp-session-archive/restic.env".source.buildCommand;

  # The very script the units run, built for the runner's own system.
  push = import ../../modules/shared/omp-session-archive-push.nix {
    inherit lib pkgs;
    machine = "fixture-host";
  };
in
pkgs.runCommand "check-omp-session-archive"
  {
    nativeBuildInputs = [
      pkgs.restic
      pkgs.jq
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.systemd ];
  }
  ''
    script=${lib.getExe push}

    # Append-only, and never the one that creates: a repository is made once, by
    # hand, because a mistyped locator would silently become a second, empty
    # archive. Comments are stripped so the negatives read only what runs.
    commands="$TMPDIR/push-commands"
    sed 's/#.*//' "$script" >"$commands"
    grep -Eq 'restic (init|forget|prune)' "$commands" && false
    grep -Fq 'restic backup' "$commands"
    grep -Fq -e '--tag omp-sessions' "$commands"
    grep -Fiq babel "$script" && false

    # An unconfigured machine is a no-op, not an hourly failure.
    (
      export HOME="$TMPDIR/unconfigured-home"
      mkdir -p "$HOME"
      "$script"
      test ! -e "$HOME/.local/state/omp-session-archive/last-success"
    )

    # A configured machine archives the roots it has, under its registry name,
    # with the tag the archive is read by, and stamps only a successful push.
    (
      export HOME="$TMPDIR/push-home"
      export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
      mkdir -p "$HOME/.omp/agent/sessions/-fixture" "$HOME/.claude/projects/-fixture" \
        "$XDG_CONFIG_HOME/omp-session-archive"
      printf '%s\n' '{"type":"session","id":"s1"}' >"$HOME/.omp/agent/sessions/-fixture/s1.jsonl"
      printf '%s\n' '{"type":"user"}' >"$HOME/.claude/projects/-fixture/c1.jsonl"
      printf 'fixture-only\n' >"$TMPDIR/push-password"
      cat >"$XDG_CONFIG_HOME/omp-session-archive/restic.env" <<ENV
    RESTIC_REPOSITORY='$TMPDIR/push-repo'
    RESTIC_PASSWORD_FILE='$TMPDIR/push-password'
    ENV
      # Not initialised: the push must fail loudly and record no success.
      if "$script" 2>/dev/null; then
        echo 'the push succeeded against a repository nobody created' >&2
        exit 1
      fi
      test ! -e "$XDG_STATE_HOME/omp-session-archive/last-success"
      test ! -e "$TMPDIR/push-repo"

      RESTIC_REPOSITORY="$TMPDIR/push-repo" RESTIC_PASSWORD_FILE="$TMPDIR/push-password" restic init --quiet >/dev/null
      "$script"
      test -s "$XDG_STATE_HOME/omp-session-archive/last-success"
      export RESTIC_REPOSITORY="$TMPDIR/push-repo" RESTIC_PASSWORD_FILE="$TMPDIR/push-password"
      restic snapshots --json --tag omp-sessions |
        jq -e 'length == 1 and .[0].hostname == "fixture-host"' >/dev/null
      restic ls --no-lock --tag omp-sessions latest >"$TMPDIR/push-listing"
      grep -q '/\.omp/agent/sessions/-fixture/s1\.jsonl$' "$TMPDIR/push-listing"
      grep -q '/\.claude/projects/-fixture/c1\.jsonl$' "$TMPDIR/push-listing"
    )

    # The units run that script with nothing of the retired archive on them.
    test ${lib.escapeShellArg service.Service.Type} = oneshot
    test ${lib.escapeShellArg (lib.concatStringsSep " " service.Unit.After)} = 'network.target'
    test ${if service ? Install then "1" else "0"} = 0
    case ${lib.escapeShellArg (inspect execStart)} in
      /nix/store/*-omp-session-archive-push/bin/omp-session-archive-push) ;;
      *) echo 'the service does not run omp-session-archive-push' >&2; exit 1 ;;
    esac
    case ${lib.escapeShellArg (inspect execStart)} in
      *babel*) echo 'the service names babel' >&2; exit 1 ;;
    esac

    test ${lib.escapeShellArg (toString timer.Timer.OnCalendar)} = hourly
    test ${lib.escapeShellArg (toString timer.Timer.Persistent)} = 1
    test ${lib.escapeShellArg (toString timer.Timer.RandomizedDelaySec)} = 10m
    test ${lib.escapeShellArg (lib.concatStringsSep " " timer.Install.WantedBy)} = 'timers.target'
    test ${lib.escapeShellArg timerGate} = ${lib.escapeShellArg envFile}

    ${lib.escapeShellArg "${pkgs.jq}/bin/jq"} -e \
      '.surfaces["omp-session-archive"].command == "clan vars generate <host>"
       and .surfaces["omp-session-archive"].declinable == false
       and (.surfaces["omp-session-archive"].implies | test("hourly timer"))
       and (.surfaceOrder | index("omp-session-archive") != null)' \
      ${../../fleet/provisioning.json} >/dev/null
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      # The shipped condition, evaluated by systemd rather than read by us. The
      # satisfiable case is tested first: a probe that cannot run at all
      # reports every condition as unmet, which would turn the assertion below
      # into one that cannot fail.
      export XDG_RUNTIME_DIR="$TMPDIR"
      configured="$TMPDIR/configured/omp-session-archive/restic.env"
      mkdir -p "$(dirname "$configured")"
      printf '%s\n' 'RESTIC_REPOSITORY=x' >"$configured"
      systemd-analyze --user condition "ConditionPathExists=$configured" >/dev/null || {
        echo 'ConditionPathExists is unsatisfiable here, so the gate below proves nothing' >&2
        exit 1
      }
      if systemd-analyze --user condition "ConditionPathExists=${envFile}" >/dev/null 2>&1; then
        echo 'the archive timer arms on a machine that has never been given the archive environment' >&2
        exit 1
      fi
    ''}

    # What activation places is derived from the custody the operator typed
    # once, and what a machine receives is the one environment it reads.
    test ${lib.escapeShellArg (toString generator.share)} = 1
    test ${lib.escapeShellArg (toString (generator.dependencies == [ "babel-custody" ]))} = 1
    test ${lib.escapeShellArg (toString generator.files."restic.env".secret)} = 1
    test ${lib.escapeShellArg generator.files."restic.env".mode} = 0600
    test ${lib.escapeShellArg generator.files."repository-password".mode} = 0600
    test ${lib.escapeShellArg (toString custody.files."cellar-env.json".deploy)} = ""
    test "$(readlink ${link})" = /run/secrets/vars/omp-session-archive/restic.env

    # No credential is an argument: the Cellar environment is read from a
    # file and rendered by jq into a file.
    generator_script=${pkgs.writeText "omp-session-archive-generator" generator.script}
    grep -Fq '"$in/babel-custody/cellar-env.json"' "$generator_script"
    grep -Fq 'tyrode-archive/omp-sessions/v1' "$generator_script"
    grep -Fq '>"$out/restic.env"' "$generator_script"

    # macOS runs the same wrapper hourly via launchd, which has no condition to
    # gate on, so the wrapper's own check of the environment file is the gate.
    test ${lib.escapeShellArg (toString darwinAgent.enable)} = 1
    case ${lib.escapeShellArg (inspect (builtins.head darwinAgent.config.ProgramArguments))} in
      /nix/store/*-omp-session-archive-push/bin/omp-session-archive-push) ;;
      *) echo 'the launchd agent does not run omp-session-archive-push' >&2; exit 1 ;;
    esac
    test ${lib.escapeShellArg (toString darwinAgent.config.StartInterval)} = 3600
    test ${lib.escapeShellArg (toString darwinAgent.config.RunAtLoad)} = 1
    test ${if darwinHasService then "1" else "0"} = 0

    # The replaced jobs are gone on both platforms.
    test ${if hasLegacy then "1" else "0"} = 0

    mkdir "$out"
  ''
