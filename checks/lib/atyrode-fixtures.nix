{ pkgs }:

{
  base = ''
    export HOME="$TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$XDG_CONFIG_HOME/atyrode" "$HOME/nix-dotfiles/.git" "$TMPDIR/bin"
    cp ${../../flake.nix} "$HOME/nix-dotfiles/flake.nix"
    printf '%s\n' '{"id":"alex-x86_64-linux"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
  '';

  gitNh = ''
    cat > "$TMPDIR/bin/git" <<'EOF'
    #!${pkgs.runtimeShell}
    if [[ "$*" == *'worktree list --porcelain'* ]]; then
      printf 'worktree %s\nworktree %s\n' "$TMPDIR/lifecycle-repo" "$HOME/.omp/wt/dirty"
      exit 0
    fi
    if [[ "$*" == *'status --porcelain'* ]]; then
      [[ "$*" == *'/malformed'* ]] && exit 1
      [[ "$*" == *'/dirty'* ]] && printf ' M fixture\n'
      exit 0
    fi
    if [[ "$*" == *'symbolic-ref --quiet --short HEAD'* ]]; then
      [[ "$*" == *'/branch-live'* ]] && printf 'omp/live\n' && exit 0
      exit 1
    fi
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
    elif [[ "''${ATYRODE_NH_NOISE:-0}" == 1 ]]; then
      echo 'Welcome to nh clean'
      echo 'legend:'
      echo 'OK: path to be kept'
      echo 'gcroots'
      echo '- OK  /home/alex/.local/state/nix/profiles/profile-9-link'
      echo '- DEL /nix/var/nix/profiles/per-user/root/channels-1-link'
      echo '/home/alex/.local/state/nix/profiles/home-manager'
      echo '- OK  /home/alex/.local/state/nix/profiles/home-manager-62-link'
      echo '> Removing /nix/var/nix/gcroots/auto/lvi04m7mn76ymzgzcx5rrifj5019psvd'
      echo '! Failed to remove path="/nix/var/nix/gcroots/auto/lvi04m7mn76ymzgzcx5rrifj5019psvd" err=Os { code: 13, kind: PermissionDenied, message: "Permission denied" } (nh/crates/nh-clean/src/clean.rs:606)'
      echo '> Removing /nix/var/nix/gcroots/auto/phm61mw9l2zpvj3fj6pmmyk22b1l3qg8'
      echo '! Failed to remove path="/nix/var/nix/gcroots/auto/phm61mw9l2zpvj3fj6pmmyk22b1l3qg8" err=Os { code: 13, kind: PermissionDenied, message: "Permission denied" } (nh/crates/nh-clean/src/clean.rs:606)'
      echo '! Failed to remove path="/nix/store/genuine" err=Os { code: 2, kind: NotFound }' >&2
    elif [[ "''${ATYRODE_NH_REAP:-0}" == 1 ]]; then
      echo '- OK  /home/alex/.local/state/nix/profiles/profile-9-link'
      echo '> Removing /nix/var/nix/gcroots/auto/lvi04m7mn76ymzgzcx5rrifj5019psvd'
      echo '> Removing /nix/var/nix/gcroots/auto/phm61mw9l2zpvj3fj6pmmyk22b1l3qg8'
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
