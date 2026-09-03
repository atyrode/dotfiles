{
  lib,
  pkgs,
  clanMachine,
}:

let
  fixtures = import ../lib/omp-fixtures.nix { inherit lib pkgs; };
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

  # The CLI, read as source: the properties about the archive timer below are
  # about what its functions may and may not do, and no rendered attribute set
  # can answer that.
  atyrodeSource = import ../lib/atyrode-source.nix { inherit pkgs; };

  # The document `babel storage configure` writes, and nothing else does. It is
  # the timer's start condition, so its exact value is part of the contract.
  # Read through an assertion rather than `or`, so a removed gate fails by name
  # instead of as a type error three lines later.
  storageDocument = "${linuxAgentTools.xdg.configHome}/babel/storage.json";
  timerGate =
    assert lib.assertMsg (linuxArchiveTimer.Unit ? ConditionPathExists)
      "the archive timer must not arm before the storage ceremony: restore ConditionPathExists on its [Unit]";
    linuxArchiveTimer.Unit.ConditionPathExists;
  # The generators, as the one clan machine this check is handed declares
  # them. The ring and the document are what activation places; the three
  # custody inputs never leave the operator's device.
  custody = clanMachine.clan.core.vars.generators.babel-custody;
  archive = clanMachine.clan.core.vars.generators.babel-archive;
  ring = custody.files."payload-keys.json";
  undeployed = map (name: custody.files.${name}.deploy) [
    "repository-password"
    "cellar-env.json"
    "catalog-env.json"
  ];
  home = clanMachine.home-manager.users.${lib.head (lib.attrNames clanMachine.home-manager.users)};
  linkTarget = name: home.xdg.configFile."babel/${name}".source;
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

    # An unconfigured machine is a no-op, not an hourly failure, and it names
    # the one command that sets a machine up.
    grep -Fq 'babel/storage.json' "$push"
    grep -Fq 'exit 0' "$push"
    grep -Fq 'atyrode apply' "$push"
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
    # the timer is started, not continuously, and the document is placed by
    # activation now, so the one thing left for the CLI to do is start the
    # timer after every activation. That step lives in apply's plan and nowhere
    # else: a provisioning offer that armed it too would be a second place, and
    # two places is how the timer ended up in two states before.
    arm=${atyrodeSource}
    grep -Fq 'systemctl" --user start babel-archive.timer' "$arm"
    awk '
      $0 ~ "^archive_converge_timer\\(\\)" { inside = 1; next }
      inside && /archive_arm_timer/ { hit = 1 }
      /^\}/ { inside = 0 }
      END { exit hit ? 0 : 1 }
    ' "$arm" || {
      echo 'atyrode: the apply step that converges the archive timer no longer arms it' >&2
      exit 1
    }
    if awk '
      $0 ~ "^provisioning_run\\(\\)" { inside = 1; next }
      inside && /babel-archive\)/ { hit = 1 }
      /^\}/ { inside = 0 }
      END { exit hit ? 0 : 1 }
    ' "$arm"; then
      echo 'atyrode: apply offers a babel ceremony again; storage is a clan var and no ceremony may exist to fetch it' >&2
      exit 1
    fi
    # An unconfigured machine is told which device owes the generation, by the
    # probe and by the apply step alike, and the policy names the same command.
    grep -Fq 'the hourly timer archives nothing until activation places it' "$arm"
    grep -Fq 'no storage document placed yet (clan vars generate' "$arm"
    ${lib.escapeShellArg "${pkgs.jq}/bin/jq"} -e \
      '.surfaces["babel-archive"].command == "clan vars generate <host>"
       and .surfaces["babel-archive"].declinable == false
       and (.surfaces["babel-archive"].implies | test("hourly timer"))' \
      ${../../fleet/provisioning.json} >/dev/null
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

    # What activation places is what custody generated, and nothing else on
    # the machine may hold the key ring: the three inputs typed at the
    # operator's device are never deployed, the ring is, at the mode babel
    # writes it itself, owned by the account that reads it.
    test ${lib.escapeShellArg (toString ring.deploy)} = 1
    test ${lib.escapeShellArg (toString ring.secret)} = 1
    test ${lib.escapeShellArg ring.mode} = 0600
    test ${lib.escapeShellArg (lib.concatMapStringsSep "," toString undeployed)} = ',,'
    test ${lib.escapeShellArg (toString (archive.dependencies == [ "babel-custody" ]))} = 1

    # Babel reads both documents where it always has, and what it finds there
    # is the placed secret rather than a copy: a copy is a second custody.
    test "$(readlink ${linkTarget "storage.json"})" = /run/secrets/vars/babel-archive/storage.json
    test "$(readlink ${linkTarget "payload-keys.json"})" = /run/secrets/vars/babel-custody/payload-keys.json

    # The ring's material never becomes a word: a pasted ring is copied
    # verbatim, and a minted key flows from urandom through a pipe into jq
    # without ever being captured, because a shell variable is one
    # substitution away from argv and argv is readable from any process
    # listing.
    custody_script=${pkgs.writeText "babel-custody-script" custody.script}
    grep -Fq 'cp "$prompts/payload-keys" "$out/payload-keys.json"' "$custody_script"
    grep -Eq 'head -c 32 /dev/urandom \| base64 \|.*\|$' "$custody_script"
    if grep -nE '(key|material|ring)="?\$\(' "$custody_script"; then
      echo 'the custody generator captures key material into a variable' >&2
      exit 1
    fi

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
