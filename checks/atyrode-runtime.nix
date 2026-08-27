{ atyrode, pkgs }:

let
  fixtures = import ./lib/atyrode-fixtures.nix { inherit pkgs; };
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
    # Runtime discovery is read-only and versioned. A generic Nix build host has
    # no WSL GPU passthrough, so it must advertise the target as unsupported
    # without allocating machine state or attempting a download.
    runtime_list="$(env -u WSL_DISTRO_NAME atyrode runtime list --json)"
    jq -e 'length == 1
      and .[0].schemaVersion == 1
      and .[0].name == "local-qwen"
      and .[0].label == "Local Qwen 3.8 27B"
      and .[0].phase == "unsupported"
      and .[0].applicable == false
      and .[0].estimatedDiskBytes == 40000000000
      and (.[0].reason | contains("WSL2"))' <<<"$runtime_list" >/dev/null
    test ! -e "$XDG_CONFIG_HOME/atyrode/runtime"
    test ! -e "$XDG_STATE_HOME/atyrode/runtime"

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
