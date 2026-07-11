{
  baseConfig,
  lib,
  pkgs,
}:

let
  agentsV1 = pkgs.writeText "codex-agents-v1.md" "managed guidance v1\n";
  configV1 = pkgs.writeText "codex-config-v1.toml" "personality = \"pragmatic\"\n";
  configV2 = pkgs.writeText "codex-config-v2.toml" "personality = \"friendly\"\n";
  fakeCodex = pkgs.writeShellApplication {
    name = "codex";
    text = ''
      printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
    '';
  };
  configuredCodex = pkgs.callPackage ../pkgs/codex-configured {
    codex = fakeCodex;
  };
  codexUseV1 = pkgs.callPackage ../pkgs/codex-use {
    managedAgents = agentsV1;
    managedConfig = configV1;
  };
  codexUseV2 = pkgs.callPackage ../pkgs/codex-use {
    managedAgents = agentsV1;
    managedConfig = configV2;
  };
in
assert lib.assertMsg (lib.all
  (
    package:
    !builtins.elem (lib.getName package) [
      "codex"
      "codex-use"
    ]
  )
  baseConfig.config.home.packages
) "a host without agent-tools must not install Codex profile tooling";
pkgs.runCommand "check-codex-use"
  {
    nativeBuildInputs = [
      codexUseV1
      codexUseV2
      configuredCodex
      pkgs.jq
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME/.codex/plugins" "$HOME/.codex/sessions"
    printf '%s\n' 'local project trust' > "$HOME/.codex/config.toml"
    printf '%s\n' 'secret sentinel' > "$HOME/.codex/auth.json"
    printf '%s\n' 'history sentinel' > "$HOME/.codex/history.jsonl"
    printf '%s\n' 'user guidance' > "$HOME/.codex/AGENTS.md"
    printf '%s\n' 'plugin sentinel' > "$HOME/.codex/plugins/state"
    test -f ${codexUseV2}/share/zsh/site-functions/_codex-use

    ${codexUseV1}/bin/codex-use converge
    test "$(cat "$HOME/.codex/config.toml")" = 'local project trust'
    test "$(cat "$HOME/.codex/auth.json")" = 'secret sentinel'
    test "$(cat "$HOME/.codex/history.jsonl")" = 'history sentinel'
    test "$(cat "$HOME/.codex/plugins/state")" = 'plugin sentinel'
    test -L "$HOME/.codex/AGENTS.md"
    test -L "$HOME/.codex/atyrode.config.toml"
    test -n "$(find "$HOME/.codex" -name 'AGENTS.md.pre-managed.*' -print -quit)"
    grep -F 'pragmatic' "$HOME/.codex/atyrode.config.toml" >/dev/null

    ${codexUseV2}/bin/codex-use converge
    grep -F 'friendly' "$HOME/.codex/atyrode.config.toml" >/dev/null
    test "$(cat "$HOME/.codex/config.toml")" = 'local project trust'

    # A live config symlinked into the store breaks Codex trust persistence;
    # converge must repair it into a mutable copy seeded from the target.
    ln -sfn ${configV1} "$HOME/.codex/config.toml"
    ${codexUseV2}/bin/codex-use converge
    test ! -L "$HOME/.codex/config.toml"
    test "$(cat "$HOME/.codex/config.toml")" = 'personality = "pragmatic"'
    test "$(stat -c %a "$HOME/.codex/config.toml")" = 600

    # A dangling store link seeds an empty mutable file instead of failing.
    ln -sfn /nix/store/00000000000000000000000000000000-gone-config.toml "$HOME/.codex/config.toml"
    ${codexUseV2}/bin/codex-use converge
    test ! -L "$HOME/.codex/config.toml"
    test ! -s "$HOME/.codex/config.toml"

    # Symlinks the user points elsewhere are their own business; leave them.
    printf '%s\n' 'hand-rolled config' > "$HOME/user-config.toml"
    ln -sfn "$HOME/user-config.toml" "$HOME/.codex/config.toml"
    ${codexUseV2}/bin/codex-use converge
    test -L "$HOME/.codex/config.toml"

    rm "$HOME/.codex/config.toml"
    printf '%s\n' 'local project trust' > "$HOME/.codex/config.toml"

    ${codexUseV2}/bin/codex-use alt
    test "$(cat "$HOME/.codex-profiles/.active-profile")" = alt
    test "$(cat "$HOME/.codex-profiles/default/config.toml")" = 'local project trust'
    test -L "$HOME/.codex/atyrode.config.toml"

    if CODEX_USE_FAILPOINT=active-staged ${codexUseV2}/bin/codex-use beta; then
      echo 'interruption failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    test -d "$HOME/.codex-profiles/.codex-use.transaction"
    ${codexUseV2}/bin/codex-use status --json | jq -e '
      .activeProfile == "alt"
      and .recoveryPending == false
      and (.mutable | index("auth.json"))
      and (.secrets | index("auth.json"))
    ' >/dev/null
    test -d "$HOME/.codex"

    if CODEX_USE_FAILPOINT=target-active ${codexUseV2}/bin/codex-use beta; then
      echo 'target-active failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    ${codexUseV2}/bin/codex-use status >/dev/null
    test "$(cat "$HOME/.codex-profiles/.active-profile")" = alt
    test -d "$HOME/.codex"

    mkdir "$HOME/.codex-profiles/alt"
    if ${codexUseV2}/bin/codex-use default >/dev/null 2>&1; then
      echo 'destination collision unexpectedly succeeded' >&2
      exit 1
    fi
    rmdir "$HOME/.codex-profiles/alt"

    if ${codexUseV2}/bin/codex-use '../bad' >/dev/null 2>&1; then
      echo 'invalid profile unexpectedly succeeded' >&2
      exit 1
    fi

    CODEX_USE_TEST_HOLD_SECONDS=2 ${codexUseV2}/bin/codex-use status >/dev/null &
    holder=$!
    for attempt in $(seq 1 100); do
      test ! -d "$HOME/.codex-profiles/.codex-use.lock" || break
      sleep 0.01
    done
    if ${codexUseV2}/bin/codex-use status >/dev/null 2>&1; then
      echo 'concurrent invocation unexpectedly acquired the lock' >&2
      exit 1
    fi
    wait "$holder"

    mkdir "$HOME/.codex-legacy"
    printf '%s\n' legacy > "$HOME/.codex-legacy/history.jsonl"
    ${codexUseV2}/bin/codex-use migrate
    test "$(cat "$HOME/.codex-profiles/legacy/history.jsonl")" = legacy

    export HOME="$TMPDIR/legacy-home"
    mkdir -p "$HOME/.codex-profiles/default"
    printf '%s\n' preserved > "$HOME/.codex-profiles/default/auth.json"
    ln -s "$HOME/.codex-profiles/default" "$HOME/.codex"
    ${codexUseV2}/bin/codex-use migrate
    test -d "$HOME/.codex"
    test ! -L "$HOME/.codex"
    test "$(cat "$HOME/.codex/auth.json")" = preserved
    test "$(cat "$HOME/.codex-profiles/.active-profile")" = default

    export CODEX_ARGS_FILE="$TMPDIR/codex-args"
    ${configuredCodex}/bin/codex exec task
    grep -F -- '--profile atyrode exec task' "$CODEX_ARGS_FILE" >/dev/null
    ${configuredCodex}/bin/codex -p custom exec task
    test "$(cat "$CODEX_ARGS_FILE")" = '-p custom exec task'
    ${configuredCodex}/bin/codex
    test "$(cat "$CODEX_ARGS_FILE")" = '--profile atyrode'
    ${configuredCodex}/bin/codex -c features.code_mode_host=true app-server --listen unix:///tmp/sock
    test "$(cat "$CODEX_ARGS_FILE")" = '-c features.code_mode_host=true app-server --listen unix:///tmp/sock'
    ${configuredCodex}/bin/codex login --api-key key
    test "$(cat "$CODEX_ARGS_FILE")" = 'login --api-key key'
    ${configuredCodex}/bin/codex resume --last
    test "$(cat "$CODEX_ARGS_FILE")" = '--profile atyrode resume --last'

    mkdir "$out"
  ''
