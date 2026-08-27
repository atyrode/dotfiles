{ lib, pkgs }:

let
  fixtures = import ./lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures) darwinAgentTools linuxAgentTools;
  linuxBackupService = linuxAgentTools.systemd.user.services.atyrode-session-backup;
  linuxBackupTimer = linuxAgentTools.systemd.user.timers.atyrode-session-backup;
  darwinBackupAgent = darwinAgentTools.launchd.agents.atyrode-session-backup;
  darwinHasBackupService = darwinAgentTools.systemd.user.services ? atyrode-session-backup;
in
pkgs.runCommand "check-agent-session-backup" { } ''
  # The sync script is append-only (`copy`, never `sync`), covers every
  # agent-session tree, and treats an unconfigured machine as a silent no-op
  # pointing at `atyrode backup setup`.
  sync=${lib.escapeShellArg linuxBackupService.Service.ExecStart}
  grep -Fq 'atyrode backup setup' "$sync"
  grep -Fq 'session-backup/env' "$sync"
  grep -Fq 'rclone copy ' "$sync"
  grep -Fq 'rclone copyto ' "$sync"
  ! grep -Fq 'rclone sync' "$sync"
  for src in .omp/agent/sessions .omp/collab .codex/sessions .codex/history.jsonl \
    .codex/session_index.jsonl .codex/attachments .claude/projects; do
    grep -Fq "$src" "$sync"
  done

  test ${lib.escapeShellArg linuxBackupService.Service.Type} = oneshot
  test ${lib.escapeShellArg (lib.concatStringsSep " " linuxBackupService.Unit.After)} = 'network.target'
  # No Install on the service: a first-run multi-GB upload inside the startup
  # transaction would hold `is-system-running` at "starting" (same rationale
  # as classifier-schedule). The timer owns scheduling.
  test ${if linuxBackupService ? Install then "1" else "0"} = 0
  test ${lib.escapeShellArg (toString linuxBackupTimer.Timer.OnCalendar)} = hourly
  test ${lib.escapeShellArg (toString linuxBackupTimer.Timer.Persistent)} = 1
  test ${lib.escapeShellArg (toString linuxBackupTimer.Timer.RandomizedDelaySec)} = 10m
  test ${lib.escapeShellArg (lib.concatStringsSep " " linuxBackupTimer.Install.WantedBy)} = 'timers.target'

  # macOS runs the same script hourly via launchd.
  test ${lib.escapeShellArg (toString darwinBackupAgent.enable)} = 1
  test ${lib.escapeShellArg (builtins.head darwinBackupAgent.config.ProgramArguments)} = "$sync"
  test ${lib.escapeShellArg (toString darwinBackupAgent.config.StartInterval)} = 3600
  test ${lib.escapeShellArg (toString darwinBackupAgent.config.RunAtLoad)} = 1
  test ${if darwinHasBackupService then "1" else "0"} = 0
  mkdir "$out"
''
