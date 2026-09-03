{ lib, pkgs }:

let
  fixtures = import ../lib/omp-fixtures.nix { inherit lib pkgs; };
  inherit (fixtures)
    brokerTokenFile
    darwinAgentTools
    linuxAgentTools
    linuxClientAgentTools
    ;
  linuxBrokerService = linuxAgentTools.systemd.user.services.atyrode-omp-auth-brokers;
  linuxBrokerSupervisor = linuxBrokerService.Service.ExecStart;
  linuxClientService = linuxClientAgentTools.systemd.user.services.atyrode-omp-auth-brokers;
  darwinBrokerAgent = darwinAgentTools.launchd.agents.atyrode-omp-auth-brokers;
  clientTarget = "alex@broker.example";

  # The role is decided in Nix and the service exists only with one: a home
  # that is not a clan machine runs neither a broker nor a tunnel. Evaluated
  # here so a regression names the missing gate rather than surfacing as a
  # stray unit in some other check's fixture.
  roleGate =
    assert lib.assertMsg (
      !(
        (fixtures.evalAgentTools pkgs { authBroker = { }; }).systemd.user.services
        ? atyrode-omp-auth-brokers
      )
    ) "a home with authBroker.role = null must define no broker service";
    assert lib.assertMsg
      ((linuxClientAgentTools.home.sessionVariables.CODE_AUTH_LOGIN_VIA or null) == clientTarget)
      "a tunnel machine must export CODE_AUTH_LOGIN_VIA naming the tunnel target, for code's OAuth login";
    assert lib.assertMsg (
      !(linuxAgentTools.home.sessionVariables ? CODE_AUTH_LOGIN_VIA)
    ) "the broker host logs in locally: it must not export CODE_AUTH_LOGIN_VIA";
    # The unit and the launchd agent gate on the placed token, so a broker host
    # whose var is not yet generated stays quiet instead of restart-looping.
    assert lib.assertMsg (
      (linuxBrokerService.Unit.ConditionPathExists or null) == brokerTokenFile
    ) "the serve unit must carry ConditionPathExists on the token file";
    assert lib.assertMsg (
      darwinBrokerAgent.config.KeepAlive == { PathState.${brokerTokenFile} = true; }
    ) "the Darwin serve agent must keep alive only while the token file is present (PathState)";
    assert lib.assertMsg (
      !(linuxClientService.Unit ? ConditionPathExists)
    ) "the tunnel unit holds no token and must not condition on one";
    assert lib.assertMsg (lib.hasInfix clientTarget linuxClientService.Unit.Description)
      "the tunnel unit's description must name its target";
    true;
in
assert roleGate;
pkgs.runCommand "check-agent-auth-broker" { } ''
    supervisor=${lib.escapeShellArg linuxBrokerSupervisor}
    test ${lib.escapeShellArg (toString darwinBrokerAgent.enable)} = 1
    test ${lib.escapeShellArg (builtins.head darwinBrokerAgent.config.ProgramArguments)} = "$supervisor"
    # The token is a shared clan var, never minted here: the supervisor may
    # not call `auth-broker token`, and the retired auth-vaults.json manifest
    # must stay absent.
    ! grep -Fq 'auth-broker token' "$supervisor"
    ! grep -Fq 'auth-vaults.json' "$supervisor"

    rm -rf /tmp/check-agent-auth-broker
    mkdir -p /tmp/check-agent-auth-broker
    export BROKER_STUB_LOG="$TMPDIR/broker-starts"
    : > "$BROKER_STUB_LOG"

    # Without the placed token the broker refuses to serve, names the path it
    # looked at, and never starts OMP.
    token_file=${lib.escapeShellArg brokerTokenFile}
    if "$supervisor" > "$TMPDIR/broker-refuse.out" 2> "$TMPDIR/broker-refuse.err"; then
      echo "the broker supervisor must exit non-zero without a placed token" >&2
      exit 1
    fi
    grep -Fq "no bearer token at $token_file" "$TMPDIR/broker-refuse.err"
    test ! -s "$BROKER_STUB_LOG"

    # With the token placed it execs OMP's serve verb on the fixed loopback bind
    # and nothing else: no `auth-broker token`, no state directory of its own.
    printf 'BROKER-TOKEN-TEST' > "$token_file"
    chmod 600 "$token_file"
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
    test ! -e /tmp/check-agent-auth-broker/xdg-state/atyrode/omp-auth-broker
    test "$(cat "$token_file")" = BROKER-TOKEN-TEST

    kill "$supervisor_pid"

    ${lib.optionalString pkgs.stdenv.isLinux ''
        # The tunnel machine forwards the broker's loopback port to the target
        # Nix gave it; nothing is read from a file to find out where, and the
        # token never reaches ssh's argv.
        export SSH_STUB_LOG="$TMPDIR/ssh-start"
        client_supervisor=${lib.escapeShellArg linuxClientService.Service.ExecStart}
        "$client_supervisor" > "$TMPDIR/client.out" 2> "$TMPDIR/client.err" &
        client_pid=$!
        trap 'kill "$client_pid" 2>/dev/null || true' EXIT
        for _ in $(seq 1 50); do
          test -s "$SSH_STUB_LOG" && break
          sleep 0.1
        done
        cat > "$TMPDIR/expected-ssh-start" <<'EOF'
      -NT
      -L
      127.0.0.1:46171:127.0.0.1:46171
      -o
      ExitOnForwardFailure=yes
      -o
      ServerAliveInterval=30
      -o
      ServerAliveCountMax=3
      ${clientTarget}
      EOF
        cmp "$TMPDIR/expected-ssh-start" "$SSH_STUB_LOG"
        ! grep -qF BROKER-TOKEN-TEST "$SSH_STUB_LOG"
        kill "$client_pid"
        wait "$client_pid"
        trap - EXIT
    ''}
    wait "$supervisor_pid"
    trap - EXIT
    touch "$out"
''
