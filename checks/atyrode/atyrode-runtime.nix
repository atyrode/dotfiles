{ atyrode, pkgs }:

let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
  manifoldGeneration =
    owner:
    pkgs.runCommand "fixture-manifold-${if owner then "owner" else "transport"}-system" { } ''
      mkdir -p "$out/etc/systemd/user"
      printf '[Unit]\nX-Atyrode-SessionOwner=%s\n[Service]\nExecStart=/fixture/manifold-agent\n' \
        '${if owner then "true" else "false"}' > "$out/etc/systemd/user/manifold-agent.service"
    '';
  splitGeneration = manifoldGeneration false;
  legacyGeneration = manifoldGeneration true;
in
pkgs.runCommand "check-atyrode-runtime"
  {
    nativeBuildInputs = [
      atyrode
      pkgs.jq
      pkgs.nix
      pkgs.yq-go
    ];
  }
  ''
    ${fixtures.base}
    ${fixtures.gitNh}
    ${fixtures.identity}
    # Runtime discovery is read-only and versioned. `runtime list` is the
    # surface `code` renders in its runtime dial (CODE_RUNTIME_BROKER=atyrode),
    # so it MUST enumerate launchable model runtimes only — never a service
    # daemon like manifold-agent, which hosts no model and whose state is
    # reachable through its own `status` verb. A generic Nix build host has no
    # WSL GPU passthrough, so the one model runtime advertises as unsupported
    # without allocating machine state or attempting a download.
    runtime_list="$(env -u WSL_DISTRO_NAME atyrode runtime list --json)"
    jq -e 'length == 1
      and .[0].schemaVersion == 1
      and .[0].name == "local-qwen"
      and .[0].label == "Local Qwen 3.8 27B"
      and .[0].phase == "unsupported"
      and .[0].applicable == false
      and .[0].estimatedDiskBytes == 40000000000
      and (.[0].reason | contains("WSL2"))
      and all(.[]; has("estimatedDiskBytes"))' <<<"$runtime_list" >/dev/null
    # The daemon stays fully reachable — just unlisted.
    jq -e '.schemaVersion == 1
      and .name == "manifold-agent"
      and .phase == "unsupported"
      and .applicable == false
      and .enrolled == false
      and .unit.present == false' \
      <<<"$(env -u WSL_DISTRO_NAME atyrode runtime status manifold-agent --json)" >/dev/null
    test ! -e "$XDG_CONFIG_HOME/atyrode/runtime"
    test ! -e "$XDG_STATE_HOME/atyrode/runtime"

    # Manifold enrollment is vault-brokered and idempotent (#418). The stubs
    # prove the wire contract: the owner key flows only through the curl
    # config file (never argv), a fresh enrollment lands a 0600 token, a
    # re-run touches neither the vault nor the master, a token-less existing
    # row demands the explicit --rotate-token recovery, and rotation mints.
    # The manager seams exercise both native paths without touching the
    # runner's user session or creating a row on the live hub.
    export ATYRODE_HOST=wsl
    export _ATYRODE_TEST_HOSTNAME=legacy-wsl
    export _ATYRODE_TEST_CURRENT_SYSTEM=${splitGeneration}
    mkdir -p "$XDG_CONFIG_HOME/systemd/user"
    ln -sfn ${splitGeneration}/etc/systemd/user/manifold-agent.service "$XDG_CONFIG_HOME/systemd/user/manifold-agent.service"
    mkdir -p "$TMPDIR/manifold-bin"
    cat > "$TMPDIR/manifold-bin/bw" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    case "$1" in
      status) printf '{"status":"unlocked"}\n' ;;
      sync) ;;
      list) printf '[{"id":"item-1","name":"manifold owner key","type":2}]\n' ;;
      get) printf '{"id":"item-1","name":"manifold owner key","type":2,"notes":"fixture-owner-key"}\n' ;;
      lock) ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/manifold-bin/curl-stub" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    config="" output="" payload="" url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --config) shift; config="$1" ;;
        -o) shift; output="$1" ;;
        -d) shift; payload="$1" ;;
        https://*) url="$1" ;;
      esac
      shift
    done
    grep -q 'Authorization: Bearer fixture-owner-key' "$config"
    [[ "$url" == https://manifold.tyrode.dev/api/actions/core.machines.enroll ]]
    printf '%s\n' "$payload" >> "$MANIFOLD_ENROLL_LOG"
    if [[ "''${MANIFOLD_ENROLL_REFUSED:-0}" == 1 ]]; then
      printf '{"ok":false,"denial":{"rule":"forbidden","message":"enrollment denied"}}\n' > "$output"
    elif [[ "$payload" == *rotateToken* ]]; then
      printf '{"ok":true,"result":{"machine":{"id":"machine-1","name":"fixture-node"},"machineToken":"rotated-token"}}\n' > "$output"
    elif [[ -e "$MANIFOLD_ROW_EXISTS" ]]; then
      printf '{"ok":true,"result":{"machine":{"id":"machine-1","name":"fixture-node"}}}\n' > "$output"
    else
      printf '{"ok":true,"result":{"machine":{"id":"machine-1","name":"fixture-node"},"machineToken":"minted-token"}}\n' > "$output"
    fi
    EOF
    chmod +x "$TMPDIR/manifold-bin/bw" "$TMPDIR/manifold-bin/curl-stub"
    cat > "$TMPDIR/bin/manifold-agent" <<'EOF'
    #!${pkgs.runtimeShell}
    exit 64
    EOF
    cat > "$TMPDIR/manifold-bin/systemctl" <<'EOF'
    #!${pkgs.runtimeShell}
    if [[ "''${MANIFOLD_MANAGER_UNKNOWN:-0}" == 1 && "$*" == *show* ]]; then exit 1; fi
    case "$*" in
      '--user cat manifold-agent.service') exit 0 ;;
      *'show --property=LoadState,ActiveState -- manifold-agent.service')
        printf 'LoadState=loaded\n'
        if [[ -e "$TMPDIR/manifold-active" ]]; then echo ActiveState=active; else echo ActiveState=inactive; fi ;;
      '--user show -P ActiveState manifold-agent.service')
        if [[ -e "$TMPDIR/manifold-active" ]]; then echo active; else echo inactive; fi ;;
      '--user show -P SubState manifold-agent.service')
        if [[ -e "$TMPDIR/manifold-active" ]]; then echo running; else echo dead; fi ;;
      '--user start manifold-agent.service' | '--user restart manifold-agent.service')
        echo "$2" >> "$TMPDIR/manifold-service-actions"
        [[ "''${MANIFOLD_START_FAIL:-0}" != 1 ]] || exit 1
        touch "$TMPDIR/manifold-active"
        cp "$HOME/.config/manifold/machine.token" "$TMPDIR/manifold-running-token"
        echo '{"evt":"welcome"}' > "$TMPDIR/manifold-events" ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/manifold-bin/journalctl" <<'EOF'
    #!${pkgs.runtimeShell}
    [[ ! -f "$TMPDIR/manifold-events" ]] || cat "$TMPDIR/manifold-events"
    EOF
    chmod +x "$TMPDIR/bin/manifold-agent" "$TMPDIR/manifold-bin/systemctl" "$TMPDIR/manifold-bin/journalctl"
    export ATYRODE_SYSTEMCTL="$TMPDIR/manifold-bin/systemctl"
    export ATYRODE_JOURNALCTL="$TMPDIR/manifold-bin/journalctl"
    export ATYRODE_BW="$TMPDIR/manifold-bin/bw"
    export ATYRODE_FETCH="$TMPDIR/manifold-bin/curl-stub"
    export MANIFOLD_ENROLL_LOG="$TMPDIR/manifold-enroll.log"
    export MANIFOLD_ROW_EXISTS="$TMPDIR/manifold-row-exists"

    # Action refusals arrive with HTTP 200; they must not install a credential
    # or be confused with an idempotent existing machine lacking a new token.
    if MANIFOLD_ENROLL_REFUSED=1 atyrode runtime provision manifold-agent > /dev/null 2>"$TMPDIR/manifold-refused.err"; then
      echo 'refused enrollment was accepted' >&2
      exit 1
    fi
    test ! -e "$HOME/.config/manifold/machine.token"
    ! grep -q -- '--rotate-token' "$TMPDIR/manifold-refused.err"

    atyrode runtime provision manifold-agent >/dev/null 2>&1
    token_file="$HOME/.config/manifold/machine.token"
    test "$(cat "$token_file")" = minted-token
    test "$(stat -c %a "$token_file")" = 600
    jq -e '.name == "wsl" and (has("rotateToken") | not)' \
      "$MANIFOLD_ENROLL_LOG" >/dev/null

    # Idempotent re-run: an enrolled machine must not touch the vault or the
    # master again — poisoned stubs prove the code path is never reached.
    ATYRODE_BW=/bin/false ATYRODE_FETCH=/bin/false \
      atyrode runtime provision manifold-agent >/dev/null 2>&1
    test "$(cat "$token_file")" = minted-token
    test "$(wc -l < "$TMPDIR/manifold-service-actions")" -eq 1
    atyrode runtime status manifold-agent --json |
      jq -e '.phase == "connected" and .machineName == "wsl"' >/dev/null
    printf '%s\n' '{"evt":"welcome"}' '{"evt":"disconnected","code":4409}' > "$TMPDIR/manifold-events"
    atyrode doctor provisioning --json |
      jq -e '.surfaces[] | select(.id == "manifold-agent") | .status == "degraded"' >/dev/null
    printf '%s\n' '{"evt":"welcome"}' '{"evt":"disconnected","code":1006}' > "$TMPDIR/manifold-events"
    atyrode runtime status manifold-agent --json | jq -e '.phase != "connected"' >/dev/null
    echo '{"evt":"welcome"}' > "$TMPDIR/manifold-events"
    rm "$TMPDIR/manifold-active"
    if MANIFOLD_START_FAIL=1 atyrode runtime provision manifold-agent > /dev/null 2>"$TMPDIR/manifold-start.err"; then
      echo 'enrollment reported success after the managed service refused to start' >&2
      exit 1
    fi
    ATYRODE_BW=/bin/false ATYRODE_FETCH=/bin/false atyrode runtime provision manifold-agent >/dev/null 2>&1
    test "$(cat "$token_file")" = minted-token
    atyrode runtime status manifold-agent --json | jq -e '.phase == "connected"' >/dev/null

    # Legacy control and rotation must refuse BEFORE a manager stop or credential revocation.
    export _ATYRODE_TEST_CURRENT_SYSTEM=${legacyGeneration}
    ln -sfn ${legacyGeneration}/etc/systemd/user/manifold-agent.service "$XDG_CONFIG_HOME/systemd/user/manifold-agent.service"
    actions_before="$(wc -l < "$TMPDIR/manifold-service-actions")"
    enrollments_before="$(wc -l < "$MANIFOLD_ENROLL_LOG")"
    for verb in stop restart; do
      set +e
      atyrode runtime "$verb" manifold-agent >/dev/null 2>&1
      result="$?"
      set -e
      test "$result" -eq 69
    done
    for manager_unknown in 0 1; do
      set +e
      MANIFOLD_MANAGER_UNKNOWN="$manager_unknown" atyrode runtime provision manifold-agent --rotate-token >/dev/null 2>&1
      result="$?"
      set -e
      test "$result" -eq 69
      test "$(cat "$token_file")" = minted-token
      test "$(wc -l < "$MANIFOLD_ENROLL_LOG")" -eq "$enrollments_before"
    done
    test "$(wc -l < "$TMPDIR/manifold-service-actions")" -eq "$actions_before"
    export _ATYRODE_TEST_CURRENT_SYSTEM=${splitGeneration}
    ln -sfn ${splitGeneration}/etc/systemd/user/manifold-agent.service "$XDG_CONFIG_HOME/systemd/user/manifold-agent.service"

    # A lost token against an existing row must refuse and name the recovery.
    rm "$token_file"
    touch "$MANIFOLD_ROW_EXISTS"
    if atyrode runtime provision manifold-agent >/dev/null 2>"$TMPDIR/manifold-lost.err"; then
      echo 'provision unexpectedly succeeded without a minted token' >&2
      exit 1
    fi
    grep -q -- --rotate-token "$TMPDIR/manifold-lost.err"
    test ! -e "$token_file"

    # Explicit rotation mints a replacement and fences the old token.
    atyrode runtime provision manifold-agent --rotate-token >/dev/null 2>&1
    test "$(cat "$token_file")" = rotated-token
    test "$(cat "$TMPDIR/manifold-running-token")" = rotated-token
    jq -e 'select(has("rotateToken")) | .rotateToken == true and .name == "wsl"' \
      "$MANIFOLD_ENROLL_LOG" >/dev/null

    # Status is a read-only probe with a stable JSON contract.
    atyrode runtime status manifold-agent --json | jq -e '
      .schemaVersion == 1
      and .name == "manifold-agent"
      and .enrolled == true
      and .machineName == "wsl"
      and (.masterUrl | startswith("https://"))
      and .unit.present == true
      and .lastLogEvent == "welcome"' >/dev/null

    # Unknown capabilities stay refused by the local-qwen helper.
    if atyrode runtime provision other-runtime >/dev/null 2>&1; then
      echo 'runtime unexpectedly accepted an unknown capability' >&2
      exit 1
    fi
    rm -rf "$HOME/.config/manifold" "$MANIFOLD_ENROLL_LOG" "$MANIFOLD_ROW_EXISTS"

    # A loaded launchd job is not necessarily running. Enrollment must load
    # a missing job, start an inactive one, and leave a live agent alone.
    export ATYRODE_HOST=macbook
    export _ATYRODE_TEST_SYSTEM=aarch64-darwin
    export _ATYRODE_TEST_HOSTNAME=legacy-mac
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.local/state/manifold"
    touch "$HOME/Library/LaunchAgents/org.nix-community.home.manifold-agent.plist"
    cat > "$TMPDIR/manifold-bin/launchctl" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$1" in
      print)
        [[ -f "$TMPDIR/manifold-loaded" ]] || exit 113
        if [[ -f "$TMPDIR/manifold-mac-active" ]]; then
          printf 'state = running\npid = 4242\n'
        else
          printf 'state = not running\n'
        fi ;;
      bootstrap)
        echo bootstrap >> "$TMPDIR/manifold-mac-actions"
        [[ "''${MANIFOLD_START_FAIL:-0}" != 1 ]] || exit 5
        touch "$TMPDIR/manifold-loaded" ;;
      kickstart)
        [[ "$2" != -k ]] || { echo 'idempotent enrollment attempted a forced restart' >&2; exit 64; }
        echo kickstart >> "$TMPDIR/manifold-mac-actions"
        [[ "''${MANIFOLD_START_FAIL:-0}" != 1 ]] || exit 5
        touch "$TMPDIR/manifold-mac-active"
        echo '{"evt":"welcome"}' > "$HOME/.local/state/manifold/agent.log" ;;
      *) exit 64 ;;
    esac
    EOF
    chmod +x "$TMPDIR/manifold-bin/launchctl"
    export ATYRODE_LAUNCHCTL="$TMPDIR/manifold-bin/launchctl"
    atyrode runtime provision manifold-agent >"$TMPDIR/manifold-mac.out" 2>"$TMPDIR/manifold-mac.err"
    jq -e '.name == "macbook"' "$MANIFOLD_ENROLL_LOG" >/dev/null
    atyrode runtime status manifold-agent --json |
      jq -e '.applicable and .enrolled and .unit.present and .phase == "connected" and .machineName == "macbook"' >/dev/null
    actions_before="$(wc -l < "$TMPDIR/manifold-mac-actions")"
    ATYRODE_BW=/bin/false ATYRODE_FETCH=/bin/false atyrode runtime provision manifold-agent >/dev/null 2>&1
    test "$(wc -l < "$TMPDIR/manifold-mac-actions")" -eq "$actions_before"
    rm "$TMPDIR/manifold-mac-active"
    atyrode doctor provisioning --json |
      jq -e '.surfaces[] | select(.id == "manifold-agent") | .status != "ok"' >/dev/null
    if MANIFOLD_START_FAIL=1 atyrode runtime provision manifold-agent >/dev/null 2>&1; then
      echo 'inactive launchd agent was reported as converged after kickstart failed' >&2
      exit 1
    fi
    ATYRODE_BW=/bin/false ATYRODE_FETCH=/bin/false atyrode runtime provision manifold-agent >/dev/null 2>&1
    test "$(cat "$token_file")" = minted-token
    ! grep -qF 'fixture-owner-key' "$TMPDIR/manifold-mac.err"
    ! grep -qF 'minted-token' "$TMPDIR/manifold-mac.err"
    rm -rf "$HOME/.config/manifold" "$HOME/.local/state/manifold" "$MANIFOLD_ENROLL_LOG" "$MANIFOLD_ROW_EXISTS"
    rm "$TMPDIR/bin/manifold-agent"
    unset ATYRODE_BW ATYRODE_FETCH ATYRODE_SYSTEMCTL ATYRODE_JOURNALCTL ATYRODE_LAUNCHCTL MANIFOLD_ENROLL_LOG MANIFOLD_ROW_EXISTS ATYRODE_HOST
    export _ATYRODE_TEST_HOSTNAME=fixture-linux
    export _ATYRODE_TEST_SYSTEM=x86_64-linux
    export _ATYRODE_TEST_CURRENT_SYSTEM="$ATYRODE_TEST_CURRENT"

    # The local model reserves its full maximum response plus tokenizer/tool
    # envelope headroom. Otherwise OMP's default 15% reserve compacts too late:
    # 150000 input+output capacity minus 32768 output is only 117232 input.
    # Generate the managed OMP profiles with the packaged runtime helper and
    # assert the emitted YAML contracts instead of pinning its heredoc source.
    runtime_helper=${atyrode}/libexec/atyrode-runtime
    runtime_profile_data="$TMPDIR/runtime-profile-data"
    mkdir -p "$runtime_profile_data"
    printf '%s\n' 'PORT=18020' > "$runtime_profile_data/.env"
    source <(${pkgs.gnused}/bin/sed '/^main "\$@"$/d' "$runtime_helper")
    DATA_DIR="$runtime_profile_data"
    write_omp_profile
    models_profile="$HOME/.omp/profiles/local-qwen/agent/models.yml"
    local_only_profile="$HOME/.omp/profiles/local-qwen/agent/local-only.yml"
    ${pkgs.yq-go}/bin/yq -o=json '.' "$models_profile" | jq -e '
      .providers["local-qwen"].models[0].maxTokens == 32768 and
      .providers["local-qwen"].models[0].contextWindow == 150000
    ' >/dev/null
    ${pkgs.yq-go}/bin/yq -o=json '.' "$local_only_profile" | jq -e '
      .compaction.methodOrder == ["soft"] and
      .compaction.asyncEnabled == true and
      .compaction.reserveTokens >= 36864 and
      .compaction.keepRecentTokens == 20000 and
      .compaction.autoContinue == true and
      (.compaction | has("snapcompact") | not)
    ' >/dev/null
    test "$(stat -c %a "$models_profile")" = 600
    test "$(stat -c %a "$local_only_profile")" = 600
    mkdir "$TMPDIR/coder-home" "$TMPDIR/developer-home"
    export _ATYRODE_TEST_USER="coder"
    export _ATYRODE_TEST_HOME="$TMPDIR/coder-home"
    export _ATYRODE_TEST_UID=1000
    export _ATYRODE_TEST_HOME_OWNER_UID=1000
    export _ATYRODE_TEST_PASSWD_HOME="$TMPDIR/coder-home"
    atyrode doctor host development-x86_64-linux --json | jq -e \
      --arg home "$TMPDIR/coder-home" '
      .ok
      and .host == "development-x86_64-linux"
      and .registered.identityMode == "runtime"
      and .registered.username == "coder"
      and .registered.homeDirectory == $home
    ' >/dev/null
    atyrode apply development-x86_64-linux --repo "$HOME/nix-dotfiles" --plan --json | jq -e \
      --arg home "$TMPDIR/coder-home" '
      .host == "development-x86_64-linux"
      and .identityMode == "runtime"
      and .gitAuthMode == "ssh"
      and .user == "coder"
      and .homeDirectory == $home
      and .backend == "nh-home"
      and .source == "local"
    ' >/dev/null
    atyrode apply development-x86_64-linux --repo "$HOME/nix-dotfiles" \
      --git-auth-mode https-gh --dry-run --restart-shell > /dev/null 2> "$TMPDIR/runtime-restart.err"
    grep -F "exec $TMPDIR/coder-home/.nix-profile/bin/zsh -l" \
      "$TMPDIR/runtime-restart.err" >/dev/null
    jq -e --arg home "$TMPDIR/coder-home" '
      .profileName == "development-x86_64-linux"
      and .username == "coder"
      and .homeDirectory == $home
      and .gitAuthMode == "https-gh"
    ' "$TMPDIR/runtime-adapter/identity.json" >/dev/null
    adapter_eval="$(${pkgs.nix}/bin/nix --extra-experimental-features nix-command eval --impure --json --expr "
      let
        flake = import $TMPDIR/runtime-adapter/flake.nix;
        evaluated = flake.outputs {
          self = {};
          dotfiles.lib.mkPortableHomeConfiguration = identity: identity;
        };
      in {
        dotfilesUrl = flake.inputs.dotfiles.url;
        identity = evaluated.homeConfigurations.development-x86_64-linux;
      }
    ")"
    jq -e --arg home "$TMPDIR/coder-home" --arg source "path:$HOME/nix-dotfiles" '
      .dotfilesUrl == $source
      and .identity.profileName == "development-x86_64-linux"
      and .identity.username == "coder"
      and .identity.homeDirectory == $home
      and .identity.gitAuthMode == "https-gh"
    ' <<<"$adapter_eval" >/dev/null
    test ! -e "$(cat "$TMPDIR/runtime-adapter-path")"
    atyrode apply development-x86_64-linux --repo "$HOME/nix-dotfiles" \
      --git-auth-mode https-gh >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/git-auth-mode")" = https-gh
    atyrode apply development-x86_64-linux --repo "$HOME/nix-dotfiles" \
      --plan --json | jq -e '.gitAuthMode == "https-gh"' >/dev/null
    if atyrode apply development-x86_64-linux --repo "$HOME/nix-dotfiles" \
      --git-auth-mode invalid >/dev/null 2>&1; then
      echo 'runtime profile unexpectedly accepted an invalid Git auth mode' >&2
      exit 1
    fi

    export _ATYRODE_TEST_USER="developer"
    export _ATYRODE_TEST_HOME="$TMPDIR/developer-home"
    export _ATYRODE_TEST_PASSWD_HOME="$TMPDIR/developer-home"
    atyrode apply development-x86_64-linux --repo "$HOME/nix-dotfiles" --plan --json | jq -e \
      --arg home "$TMPDIR/developer-home" \
      '.user == "developer" and .homeDirectory == $home and .identityMode == "runtime"' >/dev/null

    if _ATYRODE_TEST_UID=0 atyrode doctor host development-x86_64-linux --json >/dev/null 2>&1; then
      echo 'runtime profile unexpectedly accepted root' >&2
      exit 1
    fi
    if _ATYRODE_TEST_HOME_OWNER_UID=2000 \
      atyrode doctor host development-x86_64-linux --json >/dev/null 2>&1; then
      echo 'runtime profile unexpectedly accepted a foreign-owned HOME' >&2
      exit 1
    fi
    if _ATYRODE_TEST_PASSWD_HOME="$TMPDIR/other-home" \
      atyrode doctor host development-x86_64-linux --json >/dev/null 2>&1; then
      echo 'runtime profile unexpectedly accepted account HOME drift' >&2
      exit 1
    fi
    export _ATYRODE_TEST_USER="alex"
    unset _ATYRODE_TEST_HOME _ATYRODE_TEST_UID _ATYRODE_TEST_HOME_OWNER_UID \
      _ATYRODE_TEST_PASSWD_HOME
    # Inventory is a stable JSON-only surface. The test hook substitutes an
    # evaluated fixture without teaching production builds to trust environment
    # data or requiring network access in the derivation sandbox.
    cat > "$TMPDIR/inventory.json" <<'EOF'
    {
      "schemaVersion": 1,
      "identity": {"revision":"0123456789abcdef","system":"x86_64-linux","platform":"linux"},
      "authority": {"membership":"evaluated configurations","intent":"annotations","closureIncluded":false,"mutableStateIncluded":false},
      "capabilities": {"base":{"name":"base","deliverables":[]}},
      "hosts": {
        "fixture-host": {
          "id":"fixture-host",
          "description":"fixture",
          "homeDirectory":"/home/alex",
          "hostname":null,
          "platform":"linux",
          "system":"x86_64-linux",
          "username":"alex",
          "capabilities":["base"],
          "deliverables":[]
        }
      },
      "boundaries": {}
    }
    EOF
    export _ATYRODE_TEST_INVENTORY="$TMPDIR/inventory.json"
    inventory_one="$(atyrode inventory --repo "$HOME/nix-dotfiles" --json)"
    inventory_two="$(atyrode inventory --repo "$HOME/nix-dotfiles" --json)"
    test "$inventory_one" = "$inventory_two" \
      || { echo 'inventory JSON must be byte-stable for one evaluated manifest' >&2; exit 1; }
    jq -e '.schemaVersion == 1 and .identity.revision == "0123456789abcdef"' \
      <<<"$inventory_one" >/dev/null
    host_inventory="$(atyrode inventory --repo "$HOME/nix-dotfiles" --host fixture-host --json)"
    jq -e '.schemaVersion == 1 and .identity.system == "x86_64-linux"
      and .host.id == "fixture-host" and .host.capabilities == ["base"]' \
      <<<"$host_inventory" >/dev/null
    if atyrode inventory --repo "$HOME/nix-dotfiles" --host absent --json >/dev/null 2>&1; then
      echo 'inventory must reject hosts absent from the evaluated revision' >&2
      exit 1
    fi
    if atyrode inventory --repo "$HOME/nix-dotfiles" >/dev/null 2>&1; then
      echo 'inventory must require the explicit JSON contract' >&2
      exit 1
    fi

    mkdir "$out"
  ''
