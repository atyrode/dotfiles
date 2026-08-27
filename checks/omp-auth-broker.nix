{ lib, pkgs }:

let
  fixtures = import ./lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures) darwinAgentTools linuxAgentTools;
  linuxBrokerSupervisor =
    linuxAgentTools.systemd.user.services.atyrode-omp-auth-brokers.Service.ExecStart;
  darwinBrokerAgent = darwinAgentTools.launchd.agents.atyrode-omp-auth-brokers;
in
pkgs.runCommand "check-agent-auth-broker" { } ''
    supervisor=${lib.escapeShellArg linuxBrokerSupervisor}
    test ${lib.escapeShellArg (toString darwinBrokerAgent.enable)} = 1
    test ${lib.escapeShellArg (builtins.head darwinBrokerAgent.config.ProgramArguments)} = "$supervisor"
    test ${lib.escapeShellArg (toString darwinBrokerAgent.config.KeepAlive)} = 1
    # The retired auth-vaults.json manifest must stay absent from the supervisor.
    ! grep -Fq 'auth-vaults.json' "$supervisor"

    rm -rf /tmp/check-agent-auth-broker
    export BROKER_STUB_LOG="$TMPDIR/broker-starts"
    : > "$BROKER_STUB_LOG"
    "$supervisor" > "$TMPDIR/broker-serve.out" 2> "$TMPDIR/broker-serve.err" &
    supervisor_pid=$!
    trap 'kill "$supervisor_pid" 2>/dev/null || true' EXIT

    for _ in $(seq 1 50); do
      test "$(wc -l < "$BROKER_STUB_LOG")" -ge 5 && break
      sleep 0.1
    done
    test "$(wc -l < "$BROKER_STUB_LOG")" = 5
    cat > "$TMPDIR/expected-broker-start" <<'EOF'
  --profile
  default
  auth-broker
  serve
  --bind=127.0.0.1:46171
  EOF
    cmp "$TMPDIR/expected-broker-start" "$BROKER_STUB_LOG"

    token=/tmp/check-agent-auth-broker/xdg-state/atyrode/omp-auth-broker/token
    test "$(stat -c %a "$token")" = 600
    grep -Fxq -- '--profile' "$token"
    grep -Fxq default "$token"
    grep -Fxq auth-broker "$token"
    grep -Fxq token "$token"

    kill "$supervisor_pid"
    wait "$supervisor_pid"
    trap - EXIT
    touch "$out"
''
