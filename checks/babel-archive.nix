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
in
pkgs.runCommand "check-babel-archive" { } ''
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

  # macOS runs the same wrapper hourly via launchd.
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
