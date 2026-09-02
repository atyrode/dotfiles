{ lib, pkgs }:

let
  fixtures = import ../lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures) darwinAgentTools linuxAgentTools;
  linuxSliceDropIn =
    linuxAgentTools.xdg.configFile."systemd/user/app.slice.d/50-atyrode-memory.conf".text;
  linuxEarlyoomService = linuxAgentTools.systemd.user.services.atyrode-earlyoom;
  darwinHasSliceDropIn =
    darwinAgentTools.xdg.configFile ? "systemd/user/app.slice.d/50-atyrode-memory.conf";
  darwinHasEarlyoomService = darwinAgentTools.systemd.user.services ? atyrode-earlyoom;
in
pkgs.runCommand "check-agent-resource-guard" { } ''
  # Account for the stack on app.slice, but do not impose a hard ceiling.
  # MemoryMax cannot distinguish state-owning harness processes from their
  # recreatable workers; earlyoom below can, so it must see host-wide pressure.
  dropIn=${lib.escapeShellArg linuxSliceDropIn}
  grep -Fqx '[Slice]' <<<"$dropIn"
  grep -Fqx 'MemoryAccounting=yes' <<<"$dropIn"
  grep -Fqx 'MemoryMax=infinity' <<<"$dropIn"

  # MemoryHigh must stay out of the default drop-in. It throttles instead of
  # limiting: the kernel charges reclaim to the allocating thread, which on
  # this workload parked the whole slice in swap thrash - millions of throttle
  # events and tens of minutes of full stall - while never once preventing an
  # OOM. It wedged agent sessions unrecoverably and protected nothing.
  ! grep -Fq 'MemoryHigh' <<<"$dropIn"

  # earlyoom backstops host-wide exhaustion and must stay unprivileged:
  # Nice=/OOMScoreAdjust= are what upstream recommends for its *root* unit,
  # but a user service can set neither and would fail to start. Assert the
  # earlier 15% memory / 20% swap intervention point as part of the policy.
  guard=${lib.escapeShellArg linuxEarlyoomService.Service.ExecStart}
  grep -Fq 'earlyoom' "$guard"
  grep -Fq -- '-m 15' "$guard"
  grep -Fq -- '-s 20' "$guard"
  grep -Fq -- '--prefer' "$guard"
  grep -Fq -- '--avoid' "$guard"

  # Victim policy is the point of the flags, so assert the membership rather
  # than their presence. An `omp` session and the tmux server it lives in own
  # state that cannot be reconstructed - panes, worktrees, conversation
  # history - so both belong on the avoid side and must never drift back into
  # --prefer. What a session spawns is the unbounded, individually recreatable
  # half and stays preferred.
  preferList=$(grep -o -- "--prefer '[^']*'" "$guard")
  avoidList=$(grep -o -- "--avoid '[^']*'" "$guard")
  for expendable in bun node chrome MainThread; do
    grep -Fq "$expendable" <<<"$preferList"
  done
  for protected in omp; do
    grep -Fq "$protected" <<<"$avoidList"
    ! grep -Fq "$protected" <<<"$preferList"
  done
  test ${if linuxEarlyoomService.Service ? Nice then "1" else "0"} = 0
  test ${if linuxEarlyoomService.Service ? OOMScoreAdjust then "1" else "0"} = 0
  test ${lib.escapeShellArg (lib.concatStringsSep " " linuxEarlyoomService.Install.WantedBy)} = 'default.target'

  # Both mechanisms are cgroup/systemd features with no macOS analogue.
  test ${if darwinHasSliceDropIn then "1" else "0"} = 0
  test ${if darwinHasEarlyoomService then "1" else "0"} = 0
  mkdir "$out"
''
