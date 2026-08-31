{ lib, pkgs }:

let
  fixtures = import ./lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures) darwinAgentTools linuxAgentTools;
  linuxArchiveService = linuxAgentTools.systemd.user.services.babel-archive;
  linuxArchiveTimer = linuxAgentTools.systemd.user.timers.babel-archive;
  darwinArchiveAgent = darwinAgentTools.launchd.agents.babel-archive;
  darwinHasArchiveService = darwinAgentTools.systemd.user.services ? babel-archive;
  # The legacy rclone-crypt job this capability replaced. Its removal is part
  # of the contract: two hourly jobs archiving the same trees to the same
  # provider is the state that let a deleted bucket be silently re-created.
  linuxHasLegacyService = linuxAgentTools.systemd.user.services ? atyrode-session-backup;
  linuxHasLegacyTimer = linuxAgentTools.systemd.user.timers ? atyrode-session-backup;
  darwinHasLegacyAgent = darwinAgentTools.launchd.agents ? atyrode-session-backup;

  # The ceremony script and the command that runs it, read as source: the last
  # two properties here are about what these files may not contain, and no
  # rendered attribute set can answer that.
  ceremony = ../scripts/babel-storage-configure.sh;
  atyrodeSource = ../pkgs/atyrode/atyrode;

  # The document `babel storage configure` writes, and nothing else does. It is
  # the timer's start condition, so its exact value is part of the contract.
  # Read through an assertion rather than `or`, so a removed gate fails by name
  # instead of as a type error three lines later.
  storageDocument = "${linuxAgentTools.xdg.configHome}/babel/storage.json";
  timerGate =
    assert lib.assertMsg (linuxArchiveTimer.Unit ? ConditionPathExists)
      "the archive timer must not arm before the storage ceremony: restore ConditionPathExists on its [Unit]";
    linuxArchiveTimer.Unit.ConditionPathExists;
in
pkgs.runCommand "check-babel-archive"
  {
    # systemd is here only to evaluate the timer's start condition for real.
    # Every other assertion below is a pure function of the module's output.
    nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.systemd ];
  }
  ''
    push=${lib.escapeShellArg linuxArchiveService.Service.ExecStart}

    # The wrapper delegates to Babel and names no transcript paths of its own:
    # source roots come from Babel's configuration, so a tree added upstream is
    # archived without editing this repository.
    grep -Fq 'babel archive push --json' "$push"
    ! grep -Fq '.omp/agent/sessions' "$push"
    ! grep -Fq '.codex' "$push"
    ! grep -Fq '.claude' "$push"

    # rclone is gone with the legacy archive; restic is the recovery tool.
    ! grep -Fq 'rclone' "$push"

    # An unconfigured machine is a no-op, not an hourly failure, and it names the
    # one command that sets a machine up. It must not name the ceremony script by
    # path: the operator is not expected to run it, and a checkout may not exist
    # on the machine reading this message.
    grep -Fq 'babel/storage.json' "$push"
    grep -Fq 'exit 0' "$push"
    grep -Fq 'atyrode apply' "$push"
    ! grep -Fq 'babel-storage-configure' "$push"
    ! grep -Fq 'atyrode backup' "$push"

    # A repository is never created by the timer: `babel archive init` is a
    # deliberate one-time operator act, so the push must not carry it.
    ! grep -Fq 'archive init' "$push"

    # The stamp is earned from the machine-readable result, not from the push
    # merely returning. A push legitimately succeeds having archived nothing,
    # and it fails having archived only part of the tree; a stamp that cannot
    # tell those from a real archive reports health that does not exist. This
    # regressed once: an unconditional stamp recorded success on a host with no
    # source roots at all.
    grep -Fq 'last-success' "$push"
    grep -Fq 'snapshot_id' "$push"
    grep -Fq 'incomplete' "$push"

    test ${lib.escapeShellArg linuxArchiveService.Service.Type} = oneshot
    test ${lib.escapeShellArg (lib.concatStringsSep " " linuxArchiveService.Unit.After)} = 'network.target'
    # No Install on the service: a first archive can move multiple GB, and a
    # startup-transaction job that long holds `is-system-running` at "starting"
    # (same rationale as classifier-schedule). The timer owns scheduling.
    test ${if linuxArchiveService ? Install then "1" else "0"} = 0

    test ${lib.escapeShellArg (toString linuxArchiveTimer.Timer.OnCalendar)} = hourly
    # Persistent: a machine asleep at the top of the hour archives the missed
    # window once it is back, rather than dropping that session history.
    test ${lib.escapeShellArg (toString linuxArchiveTimer.Timer.Persistent)} = 1
    test ${lib.escapeShellArg (toString linuxArchiveTimer.Timer.RandomizedDelaySec)} = 10m
    test ${lib.escapeShellArg (lib.concatStringsSep " " linuxArchiveTimer.Install.WantedBy)} = 'timers.target'

    # Storage first, then the timer. Babel's SPEC.md 12 orders the rollout that
    # way and gate 728 restates it; an unconditionally armed timer inverts it,
    # because the first run can fire on a machine that holds no credential and
    # the only thing between it and an unconfigured archive is the push
    # failing. So the timer's start condition is the one document the ceremony
    # writes, and it must be that document rather than some near-neighbour: two
    # almost-identical paths would let the timer arm for a machine the push
    # then declines to archive for.
    gate=${lib.escapeShellArg timerGate}
    test "$gate" = ${lib.escapeShellArg storageDocument}
    grep -Fq 'babel/storage.json' <<<"$gate"

    # Half a gate is worse than none. systemd evaluates a start condition when
    # the timer is started, not continuously, so a machine configured after
    # activation would never arm unless the ceremony starts the timer itself --
    # and an operator who waited for an hour that never came would have no way
    # to tell a gate from a breakage. Both halves are asserted: the arming sits
    # inside the function that completes a ceremony, and apply's offer runs
    # that very command rather than the ceremony underneath it, so accepting
    # the offer and typing the command cannot leave the timer in two different
    # states.
    arm=${atyrodeSource}
    grep -Fq 'systemctl" --user start babel-archive.timer' "$arm"
    awk '
      $0 ~ "^provision_babel\\(\\) \\{" { inside = 1; next }
      inside && /archive_arm_timer/ { hit = 1 }
      /^\}/ { inside = 0 }
      END { exit hit ? 0 : 1 }
    ' "$arm" || {
      echo 'atyrode: provision_babel completes the storage ceremony without arming the archive timer' >&2
      exit 1
    }
    awk '
      $0 ~ "^archive_offer_ceremony\\(\\) \\{" { inside = 1; next }
      inside && /provision_now babel/ { hit = 1 }
      /^\}/ { inside = 0 }
      END { exit hit ? 0 : 1 }
    ' "$arm" || {
      echo "atyrode: apply's archive offer must run the command it names (atyrode provision babel), which is what arms the timer" >&2
      exit 1
    }
    # An unconfigured machine is told why nothing archives, on both the path
    # that cannot ask and the path that was told no.
    grep -Fq 'the hourly timer stays unarmed until' "$arm"
    grep -Fq 'until then the hourly timer stays unarmed' "$arm"
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      # The shipped condition, evaluated by systemd rather than read by us.
      # Asserting that the attribute merely exists would pass just as well
      # against a condition on a path that is always there, and asserting its
      # spelling would pass against a condition systemd cannot parse.
      #
      # --user because that is the scope the timer runs in, and because the
      # system scope insists on creating /run/systemd, which a build sandbox
      # does not have. That failure mode is why the satisfiable case is tested
      # first: a probe that cannot run at all reports every condition as unmet,
      # which would turn the assertion below into one that cannot fail. The
      # real document's path cannot be created here (it is outside this build's
      # directory, and the auth-broker check clears that same tree), so the
      # satisfiable case uses a local one.
      export XDG_RUNTIME_DIR="$TMPDIR"
      configured="$TMPDIR/configured/babel/storage.json"
      mkdir -p "$(dirname "$configured")"
      printf '%s\n' '{}' >"$configured"
      systemd-analyze --user condition "ConditionPathExists=$configured" >/dev/null || {
        echo 'ConditionPathExists is unsatisfiable here, so the gate below proves nothing' >&2
        exit 1
      }
      # And now the real one, on a machine that has never run the ceremony.
      if systemd-analyze --user condition "ConditionPathExists=$gate" >/dev/null 2>&1; then
        echo 'the archive timer arms on a machine that has never run the storage ceremony' >&2
        exit 1
      fi
    ''}

    # The vault session never reaches a command line. The ceremony's own header
    # gives the reason -- argv is readable from any process listing while the
    # environment is readable only by this user -- and babel SPEC.md 79 states
    # it as a rule. A Bitwarden session is read and write access to every item
    # in the vault for as long as it lasts, and `bw` reads BW_SESSION from the
    # environment on its own, so naming the session as an argument is pure
    # exposure with no benefit. That is exactly why it needs a guard rather
    # than a comment: a redundant flag reads as a harmless clarification, and
    # the leak it reopens is invisible in a diff.
    ceremony=${ceremony}
    if grep -n -- '--session' "$ceremony"; then
      echo 'the storage ceremony names the vault session on a command line; it is exported instead' >&2
      exit 1
    fi
    # The export those calls now depend on: unconditional and at top level, so
    # it holds whichever unlock branch ran, and ahead of the first call that
    # needs it. Without it the removal above would leave those calls with no
    # session at all, so this is the other half of the same property.
    export_line="$(grep -n -m1 '^export BW_SESSION$' "$ceremony" | cut -d: -f1)" || {
      echo 'the storage ceremony no longer exports the vault session unconditionally' >&2
      exit 1
    }
    first_use="$(grep -n -m1 '^bw sync' "$ceremony" | cut -d: -f1)" || {
      echo 'the storage ceremony no longer syncs the vault; re-point this ordering check' >&2
      exit 1
    }
    test -n "$export_line"
    test -n "$first_use"
    test "$export_line" -lt "$first_use"

    # macOS runs the same wrapper hourly via launchd. launchd has no condition
    # to gate on, so there the wrapper's own check of the storage document is
    # the whole gate -- which is why the push must keep it.
    test ${lib.escapeShellArg (toString darwinArchiveAgent.enable)} = 1
    test ${lib.escapeShellArg (builtins.head darwinArchiveAgent.config.ProgramArguments)} = "$push"
    test ${lib.escapeShellArg (toString darwinArchiveAgent.config.StartInterval)} = 3600
    test ${lib.escapeShellArg (toString darwinArchiveAgent.config.RunAtLoad)} = 1
    test ${if darwinHasArchiveService then "1" else "0"} = 0

    # The replaced job is gone on both platforms.
    test ${if linuxHasLegacyService then "1" else "0"} = 0
    test ${if linuxHasLegacyTimer then "1" else "0"} = 0
    test ${if darwinHasLegacyAgent then "1" else "0"} = 0

    mkdir "$out"
  ''
