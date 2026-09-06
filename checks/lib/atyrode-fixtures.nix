{ pkgs }:

let
  generation =
    name:
    pkgs.runCommand name { } ''
      mkdir -p "$out/home-files/.config/systemd/user" \
        "$out/etc/systemd/system" "$out/etc/systemd/user" \
        "$out/Library/LaunchDaemons" "$out/Library/LaunchAgents"
      printf '#!%s\nexit 0\n' '${pkgs.runtimeShell}' > "$out/activate"
      chmod +x "$out/activate"
    '';
in

{
  base = ''
    export HOME="$TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$XDG_CONFIG_HOME/atyrode" "$HOME/nix-dotfiles/.git" "$TMPDIR/bin"
    cp ${../../flake.nix} "$HOME/nix-dotfiles/flake.nix"
    printf '%s\n' '{"id":"development-x86_64-linux"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
    # `atyrode apply` converges the account login shell, so every check that
    # activates now depends on what the account database says. A sandbox has no
    # login shell and no way to set one, so the default is a machine whose
    # shell is already right; a check that is actually about convergence
    # overrides this with a fixture describing the drift it wants.
    printf '%s\n' '{"loginShell":{"path":"PLACEHOLDER","executable":true,"listed":true}}' \
      > "$TMPDIR/settled-login-shell.json"
    ${pkgs.jq}/bin/jq --arg path "$HOME/.nix-profile/bin/zsh" '.loginShell.path = $path' \
      "$TMPDIR/settled-login-shell.json" > "$TMPDIR/settled-login-shell.json.tmp"
    mv "$TMPDIR/settled-login-shell.json.tmp" "$TMPDIR/settled-login-shell.json"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$TMPDIR/settled-login-shell.json"
    export ATYRODE_TEST_CANDIDATE=${generation "fixture-candidate-home-manager-generation"}
    export ATYRODE_TEST_CURRENT=${generation "fixture-current-home-manager-generation"}
    export _ATYRODE_TEST_CURRENT_SYSTEM="$ATYRODE_TEST_CURRENT"
    mkdir -p "$XDG_STATE_HOME/home-manager/gcroots"
    ln -s "$ATYRODE_TEST_CURRENT" "$XDG_STATE_HOME/home-manager/gcroots/current-home"
  '';

  gitNh = ''
    cat > "$TMPDIR/bin/git" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      *rev-parse\ --is-inside-work-tree*) echo true ;;
      *rev-parse\ --short=12\ HEAD*) echo 0123456789ab ;;
      *rev-parse\ HEAD*) echo 0123456789abcdef0123456789abcdef01234567 ;;
      *diff\ --quiet*) exit 0 ;;
      *ls-remote*) printf 'feedfacefeedfacefeedfacefeedfacefeedface\trefs/heads/main\n' ;;
      *) exit 1 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/nh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" > "$TMPDIR/nh-args"
    printf '%s\n' "''${LC_ALL-}" > "$TMPDIR/nh-locale"
    printf '%s\n' "$*" >> "$TMPDIR/nh-history"
    output=""
    previous=""
    for argument in "$@"; do
      [[ "$previous" != -o ]] || output="$argument"
      previous="$argument"
    done
    if [[ -n "$output" ]]; then
      [[ -d "$ATYRODE_TEST_CANDIDATE" ]] || exit 1
      ln -sfn "$ATYRODE_TEST_CANDIDATE" "$output"
    elif [[ "''${2:-}" == switch && "$*" != *" --dry"* ]]; then
      [[ "''${3:-}" == /nix/store/* && -d "$3" ]] || exit 64
      printf '%s\n' "$*" >> "$TMPDIR/nh-activations"
    fi
    if [[ -n "''${ATYRODE_NH_DELAY:-}" ]]; then
      : > "$TMPDIR/nh-started"
      sleep "$ATYRODE_NH_DELAY"
      printf 'detached activation completed\n'
    fi
    if [[ "$*" == *"--configuration development-x86_64-linux"* ]]; then
      adapter="''${3#path:}"
      printf '%s\n' "$adapter" > "$TMPDIR/runtime-adapter-path"
      mkdir -p "$TMPDIR/runtime-adapter"
      cp "$adapter/flake.nix" "$TMPDIR/runtime-adapter/flake.nix"
      cp "$adapter/identity.json" "$TMPDIR/runtime-adapter/identity.json"
    fi
    if [[ "$*" == *"home switch"* && "$*" == *" --dry"* ]]; then
      printf '\033[?25l⠋ Building\r⏱ 0s\rFinished at 14:18:57 after 0s\n'
      printf '\033[1m<<<\033[0m /nix/store/old-home-manager-generation\n'
      printf '\033[1m>>>\033[0m /nix/store/new-home-manager-generation\n\n'
      printf 'CHANGED\n[U.] alpha 1.0 -> 2.0, +9.67 KiB\n[D.] beta 3.0 -> 2.5, -1.00 MiB\n[C.] source -9.67 KiB\n\n'
      printf 'ADDED\n[A+] gamma 4.0, +2.00 MiB\n\n'
      printf 'REMOVED\n[R-] delta 5.0, -7.00 MiB\n\n'
      printf 'PATHS: 7529 -> 7536 (+5054, -5047)\nSIZE: 1.50 GiB -> 1.49 GiB\nDIFF: -5.59 MiB\033[?25h\n'
    fi
    [[ "''${ATYRODE_NH_FAIL:-0}" != 1 ]]
    EOF
    chmod +x "$TMPDIR/bin/git" "$TMPDIR/bin/nh"
    export PATH="$TMPDIR/bin:$PATH"
    export ATYRODE_GIT="$TMPDIR/bin/git"
    export ATYRODE_NH="$TMPDIR/bin/nh"
  '';

  identity = ''
    export _ATYRODE_TEST_HOSTNAME="fixture-linux"
    export _ATYRODE_TEST_SYSTEM="x86_64-linux"
    export _ATYRODE_TEST_USER="alex"
  '';
}
