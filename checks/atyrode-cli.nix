{ pkgs }:

pkgs.runCommand "check-atyrode-cli"
  {
    nativeBuildInputs = [
      pkgs.atyrode
      pkgs.jq
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$XDG_CONFIG_HOME/atyrode" "$HOME/nix-dotfiles/.git" "$TMPDIR/bin"
    cp ${../flake.nix} "$HOME/nix-dotfiles/flake.nix"
    printf '%s\n' '{"id":"alex-x86_64-linux"}' > "$XDG_CONFIG_HOME/atyrode/host.json"

    cat > "$TMPDIR/bin/git" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      *rev-parse\ --is-inside-work-tree*) echo true ;;
      *rev-parse\ --short=12\ HEAD*) echo 0123456789ab ;;
      *diff\ --quiet*) exit 0 ;;
      *) exit 1 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/nh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" > "$TMPDIR/nh-args"
    [[ "''${ATYRODE_NH_FAIL:-0}" != 1 ]]
    EOF
    chmod +x "$TMPDIR/bin/git" "$TMPDIR/bin/nh"
    export PATH="$TMPDIR/bin:$PATH"
    export ATYRODE_GIT="$TMPDIR/bin/git"
    export ATYRODE_NH="$TMPDIR/bin/nh"
    export _ATYRODE_TEST_HOSTNAME="fixture-linux"
    export _ATYRODE_TEST_SYSTEM="x86_64-linux"
    export _ATYRODE_TEST_USER="alex"

    atyrode capabilities list --json | jq -e 'index("base") and index("server")' >/dev/null
    atyrode capabilities show alex-linux --json | jq -e '.host == "alex-x86_64-linux"' >/dev/null
    atyrode doctor host --json | jq -e '.ok and .registered.id == "alex-x86_64-linux"' >/dev/null
    atyrode apply --repo "$HOME/nix-dotfiles" --plan --json | jq -e '
      .host == "alex-x86_64-linux"
      and .backend == "nh-home"
      and .revision == "0123456789ab"
      and .mutationBoundary == "activation only after preflight"
    ' >/dev/null
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"

    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = alex-x86_64-linux
    test -z "$(find "$XDG_STATE_HOME/atyrode" -name '.dotfiles-config.*' -print -quit)"

    printf '%s\n' sentinel > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    export ATYRODE_NH_FAIL=1
    if atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>&1; then
      echo 'failed activation unexpectedly succeeded' >&2
      exit 1
    fi
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    unset ATYRODE_NH_FAIL

    atyrode apply --repo "$HOME/nix-dotfiles" --dry-run >/dev/null
    grep -F -- 'home switch ' "$TMPDIR/nh-args" >/dev/null
    grep -F -- '--dry' "$TMPDIR/nh-args" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

    if atyrode apply alex-aarch64-linux --plan >/dev/null 2>&1; then
      echo 'cross-system host selection unexpectedly succeeded' >&2
      exit 1
    fi

    mkdir "$out"
  ''
