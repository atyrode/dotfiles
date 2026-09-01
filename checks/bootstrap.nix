{ pkgs }:

let
  system = pkgs.stdenv.hostPlatform.system;
  nixHashes = {
    "aarch64-darwin" = "71e18301c4ea78c667f2753159156b5bdb899993720e8aa7bcca97e8312d3d6b";
    "aarch64-linux" = "f1cee64ae7a02330c6421924c28f597c41813f2214ff108622087d8056378b08";
    "x86_64-linux" = "eafe5042404e818505e28c5ca3d0885f3ec45c31f955489a25bb38258f87560e";
  };
  expectedHash = nixHashes.${system};
  darwinHash = nixHashes."aarch64-darwin";
in
pkgs.runCommand "check-bootstrap-${system}"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.shellcheck
    ];
  }
  ''
    set -euo pipefail
    # Assertions here are bare `test` and `grep`, so a failure exits silently
    # and the build log ends mid-scenario with nothing to read. Name the
    # command and the scenario it belongs to instead. Paths where a failure is
    # itself the assertion detach the trap, so this only ever names a fault.
    #
    # The run under test writes a log and a transcript per managed step, and a
    # scenario that discards stdout leaves them as the only account of what
    # happened. Print them here: a failure that reproduces once in ten runs is
    # the one that must not need a second run to be readable. The trap fires
    # again as the failure propagates out through stdenv, so dump only once.
    fixture_name=""
    reported=0
    report_check_failure() {
      echo "check failed in fixture '$fixture_name': $BASH_COMMAND" >&2
      [ "$reported" = 0 ] || return 0
      reported=1
      local log
      for log in "''${XDG_STATE_HOME:-}"/atyrode/bootstrap/logs/*; do
        [ -f "$log" ] || continue
        echo "--- $log" >&2
        cat "$log" >&2
      done
    }
    trap 'report_check_failure' ERR

    bootstrap=${../install.sh}
    real_git=${pkgs.git}/bin/git
    base_path="$PATH"
    host="alex-${system}"
    tool_root="$TMPDIR/tools"
    fresh_tools="$tool_root/fresh"
    managed_tools="$tool_root/managed"
    fake_nix_template="$tool_root/fake-nix"
    fake_installer_template="$tool_root/fake-installer"

    bash -n "$bootstrap"
    shellcheck -x "$bootstrap"
    if grep -Eq 'mapfile|declare -A|local -n|\[\[ -v |\$\{[^}]+,,\}|flock|stat -c' \
      "$bootstrap"; then
      echo 'bootstrap uses a construct unavailable before Nix or on Bash 3.2' >&2
      exit 1
    fi

    mkdir -p "$fresh_tools" "$managed_tools"

    cat > "$tool_root/git" <<'EOF'
    #!${pkgs.runtimeShell}
    if [ -n "''${FAKE_GIT_UPDATE_REPO:-}" ]; then
      worktree=""
      previous=""
      is_fetch=0
      for argument in "$@"; do
        if [ "$previous" = -C ]; then
          worktree="$argument"
        fi
        if [ "$argument" = fetch ]; then
          is_fetch=1
        fi
        previous="$argument"
      done
      if [ "$is_fetch" = 1 ]; then
        exec ${pkgs.git}/bin/git -C "$worktree" fetch \
          "$FAKE_GIT_UPDATE_REPO" +main:refs/remotes/origin/main
      fi
    fi
    if [ "''${FAKE_GIT_FETCH_FAIL:-0}" = 1 ]; then
      for argument in "$@"; do
        if [ "$argument" = fetch ]; then
          exit 69
        fi
      done
    fi
    exec ${pkgs.git}/bin/git "$@"
    EOF

    cat > "$tool_root/curl" <<'EOF'
    #!${pkgs.runtimeShell}
    if [ "''${FAKE_CURL_FAIL:-0}" = 1 ]; then
      exit 69
    fi
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --output ]; then
        output="$2"
        shift 2
      else
        shift
      fi
    done
    [ -n "$output" ] || exit 64
    printf 'verified fixture archive\n' > "$output"
    EOF

    cat > "$tool_root/sha256sum" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$1" in
      */nix.tar.xz)
        if [ "''${FAKE_BAD_SHA:-0}" = 1 ]; then
          printf '%064d  %s\n' 0 "$1"
        else
          printf '%s  %s\n' "$EXPECTED_NIX_SHA" "$1"
        fi
        ;;
      *) exec "$REAL_SHA256SUM" "$1" ;;
    esac
    EOF

    cat > "$tool_root/shasum" <<'EOF'
    #!${pkgs.runtimeShell}
    if [ "$1" = -a ]; then
      shift 2
    fi
    exec "$FAKE_SHA256SUM" "$@"
    EOF

    # Marks the environment as privileged so a stand-in for a tool that really
    # needs root - reading the System keychain - can tell the difference. An
    # unprivileged keychain read finds nothing and looks exactly like a volume
    # whose key is gone, which is a rename quietly escalating into a delete.
    cat > "$tool_root/sudo" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    if [ "''${1:-}" = -- ]; then
      shift
    fi
    export FAKE_PRIVILEGED=1
    exec "$@"
    EOF

    cat > "$tool_root/gh" <<'EOF'
    #!${pkgs.runtimeShell}
    [ "$#" -eq 2 ] && [ "$1" = auth ] && [ "$2" = status ] || exit 64
    [ "''${FAKE_GH_AUTH:-0}" = 1 ]
    EOF

    cat > "$fake_installer_template" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    : > "$FAKE_INSTALL_EXECUTED"
    printf '%s\n' "$*" > "$FAKE_INSTALL_ARGS"
    if [ -n "''${FAKE_INSTALLER_FAIL_MESSAGE:-}" ]; then
      printf '%s\n' "$FAKE_INSTALLER_FAIL_MESSAGE"
      exit 71
    fi
    if [ "''${FAKE_INSTALLER_FAIL_AFTER_START:-0}" = 1 ]; then
      exit 71
    fi
    mkdir -p "$HOME/.nix-profile/bin" "$HOME/.nix-profile/etc/profile.d"
    cp "$FAKE_NIX_TEMPLATE" "$HOME/.nix-profile/bin/nix"
    chmod +x "$HOME/.nix-profile/bin/nix"
    printf '%s\n' 'export PATH="$HOME/.nix-profile/bin:$PATH"' \
      > "$HOME/.nix-profile/etc/profile.d/nix.sh"
    EOF

    cat > "$tool_root/tar" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    destination=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -C ]; then
        destination="$2"
        shift 2
      else
        shift
      fi
    done
    [ -n "$destination" ] || exit 64
    extracted="$destination/nix-2.34.7-$FAKE_SYSTEM"
    mkdir -p "$extracted"
    cp "$FAKE_INSTALLER_TEMPLATE" "$extracted/install"
    chmod +x "$extracted/install"
    EOF

    cat > "$fake_nix_template" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" >> "$FAKE_LOG"
    case " $* " in
      *" -- apply "*)
        case " $* " in
          *" --plan "*) exit 0 ;;
        esac
        # nix-darwin's own refusal, reprinted the way nh reprints it: the
        # block arrives indented under nh's error, so a parser that only
        # matches column zero passes the check and fails on a real machine.
        if [ -n "''${FAKE_ETC_CONFLICTS:-}" ]; then
          {
            printf 'Error: \n'
            printf '   0: Darwin activation failed\n'
            printf '      stderr:\n'
            printf '      error: Unexpected files in /etc, aborting activation\n'
            printf '      The following files have unrecognized content and would be overwritten:\n'
            printf '\n'
            for conflict in ''${FAKE_ETC_CONFLICTS}; do
              printf '        %s\n' "$conflict"
            done
            printf '\n'
            printf '      Please check there is nothing critical in these files, rename them by adding .before-nix-darwin to the end, and then try again.\n'
          } >&2
          exit 2
        fi
        # nh builds the closure before it switches, so this failure never
        # reached the machine. The wording is nix's own, because the classifier
        # reads the transcript rather than an exit code.
        if [ "''${FAKE_BUILD_FAIL:-0}" = 1 ]; then
          {
            printf "error: Cannot build '/nix/store/00000000000000000000000000000000-darwin-system-26.11.drv'.\n"
            printf '       Reason: builder failed with exit code 1.\n'
          } >&2
          exit 1
        fi
        if [ "''${FAKE_ACTIVATION_FAIL:-0}" = 1 ]; then
          exit 70
        fi
        want_config=0
        config=""
        for argument in "$@"; do
          if [ "$want_config" = 1 ]; then
            config="$argument"
            break
          fi
          if [ "$argument" = apply ]; then
            want_config=1
          fi
        done
        [ -n "$config" ] || exit 64
        mkdir -p "$XDG_STATE_HOME/atyrode"
        printf '%s\n' "$config" > "$XDG_STATE_HOME/atyrode/dotfiles-config"
        rm -f "$HOME/.zshrc" "$HOME/.zshenv"
        ln -s /nix/store/fixture-home-manager-files/.zshrc "$HOME/.zshrc"
        ln -s /nix/store/fixture-home-manager-files/.zshenv "$HOME/.zshenv"
        mkdir -p "$HOME/.nix-profile/bin"
        ln -sf ${pkgs.zsh}/bin/zsh "$HOME/.nix-profile/bin/zsh"
        ;;
      # Bootstrap's verification step invokes the aggregate `atyrode doctor
      # <host>` with no family subcommand, so one branch answers for it. Its
      # two failure shapes are deliberately distinct: 69 is doctor's own "a
      # family is incomplete", which is a finished bootstrap with findings,
      # and anything else is a verification that genuinely broke. Collapsing
      # them is what reported a healthy Mac as [BOOT-E399].
      *" -- doctor "*)
        if [ "''${FAKE_DOCTOR_FINDINGS:-0}" = 1 ]; then
          printf 'container-engine: incomplete\n'
          exit 69
        fi
        [ "''${FAKE_VERIFY_FAIL:-0}" != 1 ]
        ;;
      *) exit 64 ;;
    esac
    EOF

    # A volume table stands in for diskutil: "name<TAB>device<TAB>uuid" per
    # line, with an optional fourth field of "no" for unmounted and an optional
    # fifth of "locked" for an encrypted volume whose key is needed to mount.
    # Both are modelled because both decide which operations are legal: a
    # rename goes through the mounted filesystem, and a locked volume refuses
    # to mount at all. A table that is always mounted and never encrypted
    # cannot tell a correct retirement from one that fails on the real machine.
    cat > "$tool_root/diskutil" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    table="''${FAKE_VOLUMES:-}"
    { [ -n "$table" ] && [ -f "$table" ]; } || exit 1
    tab="$(printf '\t')"
    matches() { [ "$1" = "$2" ] || [ "$1" = "$3" ] || [ "$1" = "$4" ]; }

    action="''${1:-}"
    shift || true
    passphrase=""
    if [ "$action" = apfs ]; then
      action="''${1:-}"
      shift || true
      case "$action" in
        deleteVolume) action=delete ;;
        unlockVolume) action=unlock ;;
        *) exit 64 ;;
      esac
    fi
    case "$action" in
      info | rename | mount | unmount | delete | unlock) ;;
      *) exit 64 ;;
    esac
    # unmount takes an optional force before the device.
    [ "''${1:-}" != force ] || shift
    target="''${1:-}"
    [ -n "$target" ] || exit 64
    if [ "$action" = unlock ]; then
      [ "''${2:-}" = -stdinpassphrase ] || exit 64
      passphrase="$(cat)"
    fi

    found=0
    : > "$table.next"
    while IFS="$tab" read -r name device uuid mounted locked; do
      [ -n "$name" ] || continue
      mounted="''${mounted:-yes}"
      locked="''${locked:-}"
      if matches "$target" "$name" "$device" "$uuid"; then
        found=1
        case "$action" in
          info)
            printf '   Device Identifier:         %s\n' "$device"
            printf '   Volume Name:               %s\n' "$name"
            printf '   Volume UUID:               %s\n' "$uuid"
            if [ "$mounted" = no ]; then
              printf '   Mounted:                   No\n'
            else
              printf '   Mounted:                   Yes\n'
            fi
            rm -f "$table.next"
            exit 0
            ;;
          rename)
            if [ "$mounted" = no ]; then
              echo 'Volume must be mounted' >&2
              rm -f "$table.next"
              exit 1
            fi
            name="$2"
            ;;
          mount)
            if [ "$locked" = locked ]; then
              echo 'Volume is locked' >&2
              rm -f "$table.next"
              exit 1
            fi
            mounted=yes
            ;;
          unlock)
            if [ "$passphrase" != "''${FAKE_VOLUME_PASSPHRASE:-}" ] || [ -z "$passphrase" ]; then
              echo 'Incorrect passphrase' >&2
              rm -f "$table.next"
              exit 1
            fi
            locked=""
            mounted=yes
            ;;
          unmount) mounted=no ;;
          delete) continue ;;
        esac
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$device" "$uuid" "$mounted" "$locked" >> "$table.next"
    done < "$table"
    [ "$found" = 1 ] || { rm -f "$table.next"; exit 1; }
    mv "$table.next" "$table"
    EOF

    # The installer keeps an encrypted volume's passphrase in the System
    # keychain under the volume UUID, and bootstrap reads it the same way
    # upstream does. No entry means a volume that cannot be unlocked.
    cat > "$tool_root/security" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    [ "''${1:-}" = find-generic-password ] || exit 64
    # The System keychain is root-only, so an unprivileged read finds nothing.
    [ "''${FAKE_PRIVILEGED:-0}" = 1 ] || exit 44
    [ -n "''${FAKE_VOLUME_PASSPHRASE:-}" ] || exit 44
    [ "''${FAKE_KEYCHAIN_UUID:-}" = "''${3:-}" ] || exit 44
    printf '%s\n' "$FAKE_VOLUME_PASSPHRASE"
    EOF

    # A launchd plist on macOS is commonly a binary file whose strings are not
    # greppable. The fixture models one as a marker line plus base64, so a
    # scenario staging it proves bootstrap decodes rather than greps: raw sed
    # over this file finds nothing.
    cat > "$tool_root/plutil" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    # plutil -convert xml1 -o - FILE: the file is the trailing argument.
    [ "''${1:-}" = -convert ] || exit 64
    shift 4
    file="$1"
    if IFS= read -r marker < "$file" && [ "$marker" = bplist00 ]; then
      sed 1d "$file" | ${pkgs.coreutils}/bin/base64 -d
    else
      cat "$file"
    fi
    EOF

    # launchctl records the bootout so a scenario can prove the daemon was
    # stopped before its plist was removed. An already-unloaded daemon exits
    # non-zero, which is the state being converged on, not a failure.
    cat > "$tool_root/launchctl" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    [ "''${1:-}" = bootout ] || exit 64
    [ -z "''${FAKE_LAUNCHCTL_LOG:-}" ] || printf '%s\n' "$2" >> "$FAKE_LAUNCHCTL_LOG"
    [ "''${FAKE_LAUNCHCTL_LOADED:-1}" = 1 ] || exit 3
    EOF

    chmod +x \
      "$tool_root/git" \
      "$tool_root/curl" \
      "$tool_root/sha256sum" \
      "$tool_root/shasum" \
      "$tool_root/sudo" \
      "$tool_root/gh" \
      "$tool_root/tar" \
      "$tool_root/diskutil" \
      "$tool_root/plutil" \
      "$tool_root/launchctl" \
      "$tool_root/security" \
      "$fake_installer_template" \
      "$fake_nix_template"
    for tool in git curl sha256sum shasum sudo gh tar diskutil plutil launchctl security; do
      ln -s "$tool_root/$tool" "$fresh_tools/$tool"
      ln -s "$tool_root/$tool" "$managed_tools/$tool"
    done
    ln -s "$fake_nix_template" "$managed_tools/nix"

    new_fixture() {
      fixture_name="$1"
      export HOME="$TMPDIR/$fixture_name/home"
      export XDG_STATE_HOME="$HOME/.local/state"
      export BOOTSTRAP_NIX_PROFILE_SCRIPT="$HOME/.nix-profile/etc/profile.d/nix.sh"
      repo="$TMPDIR/$fixture_name/repo"
      export FAKE_LOG="$TMPDIR/$fixture_name/nix.log"
      export FAKE_INSTALL_EXECUTED="$TMPDIR/$fixture_name/installer-executed"
      export FAKE_INSTALL_ARGS="$TMPDIR/$fixture_name/installer-args"
      export FAKE_NIX_TEMPLATE="$fake_nix_template"
      export FAKE_INSTALLER_TEMPLATE="$fake_installer_template"
      export FAKE_SHA256SUM="$tool_root/sha256sum"
      export REAL_SHA256SUM=${pkgs.coreutils}/bin/sha256sum
      export FAKE_SYSTEM=${system}
      export EXPECTED_NIX_SHA=${expectedHash}
      case "$FAKE_SYSTEM" in
        *-linux)
          export FAKE_EXPECTED_LOGIN_SHELL="$HOME/.nix-profile/bin/zsh"
          export FAKE_EXPECTED_INSTALL_ARGS="--no-daemon --yes --no-channel-add --no-modify-profile"
          ;;
        *-darwin)
          export FAKE_EXPECTED_LOGIN_SHELL=/run/current-system/sw/bin/zsh
          export FAKE_EXPECTED_INSTALL_ARGS="--daemon --yes --no-channel-add --no-modify-profile"
          ;;
        *) exit 64 ;;
      esac
      unset \
        ATYRODE_GIT_AUTH_MODE \
        BOOTSTRAP_FORCE_SYSTEM \
        BOOTSTRAP_PROFILE_TARGET_ROOT \
        BOOTSTRAP_TEST_COLOR \
        BOOTSTRAP_TEST_TTY \
        CODER_AGENT_URL \
        CODER_WORKSPACE_NAME \
        FAKE_ACTIVATION_FAIL \
        FAKE_BUILD_FAIL \
        FAKE_BAD_SHA \
        FAKE_CURL_FAIL \
        FAKE_ETC_CONFLICTS \
        FAKE_GH_AUTH \
        FAKE_GIT_FETCH_FAIL \
        FAKE_GIT_UPDATE_REPO \
        FAKE_INSTALLER_FAIL_AFTER_START \
        FAKE_INSTALLER_FAIL_MESSAGE \
        FAKE_DOCTOR_FINDINGS \
        FAKE_VERIFY_FAIL \
        FAKE_VOLUMES
      mkdir -p "$HOME" "$repo"
      cp "$bootstrap" "$repo/install.sh"
      substituteInPlace "$repo/install.sh" \
        --replace-fail 'readonly BOOTSTRAP_TEST_HOOKS=0' \
        'readonly BOOTSTRAP_TEST_HOOKS=1'
      chmod +x "$repo/install.sh"
      patchShebangs "$repo/install.sh"
      printf '{ outputs = _: {}; }\n' > "$repo/flake.nix"
      "$real_git" -C "$repo" init -q -b main
      "$real_git" -C "$repo" config user.name fixture
      "$real_git" -C "$repo" config user.email fixture@example.invalid
      "$real_git" -C "$repo" remote add origin https://github.com/atyrode/dotfiles.git
      "$real_git" -C "$repo" add flake.nix install.sh
      "$real_git" -C "$repo" commit -q -m fixture
      "$real_git" -C "$repo" update-ref refs/remotes/origin/main HEAD
    }

    # The macOS repairs are the reason bootstrap has a platform override: the
    # states they fix cannot be built on a Linux runner, but the logic that
    # fixes them must still be covered by every CI job.
    darwin_fixture() {
      new_fixture "$1"
      export BOOTSTRAP_FORCE_SYSTEM=aarch64-darwin
      export FAKE_SYSTEM=aarch64-darwin
      export EXPECTED_NIX_SHA=${darwinHash}
      export FAKE_EXPECTED_LOGIN_SHELL=/run/current-system/sw/bin/zsh
      export FAKE_EXPECTED_INSTALL_ARGS="--daemon --yes --no-channel-add --no-modify-profile"
      export BOOTSTRAP_PROFILE_TARGET_ROOT="$TMPDIR/$1/etcroot"
      export FAKE_VOLUMES="$TMPDIR/$1/volumes"
      # macOS reaches /etc through a symlink to private/etc, and traversal
      # that refuses to follow the starting point finds nothing at all. A
      # fixture with a real directory here cannot catch that, so it models
      # the indirection.
      etc="$BOOTSTRAP_PROFILE_TARGET_ROOT/etc"
      mkdir -p "$BOOTSTRAP_PROFILE_TARGET_ROOT/private/etc"
      ln -s private/etc "$etc"
      : > "$FAKE_VOLUMES"
    }

    expect_failure() {
      if "$@" > "$TMPDIR/unexpected-success.out" 2> "$TMPDIR/expected-failure.err"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
      fi
    }

    # A clean plan is read-only and never invokes Nix, downloads, or creates receipts.
    new_fixture plan
    export PATH="$managed_tools:$base_path"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/plan.out"
    grep -q '^Preflight passed' "$TMPDIR/plan.out"
    grep -q '^Plan' "$TMPDIR/plan.out"
    test ! -e "$FAKE_LOG"
    test ! -e "$XDG_STATE_HOME"
    expect_failure "$repo/install.sh"
    test ! -e "$FAKE_LOG"
    test ! -e "$XDG_STATE_HOME"

    # Production bootstrap ignores ambient test hooks, including an arbitrary
    # profile script that would otherwise be sourced before activation.
    cat > "$TMPDIR/poison-profile" <<'EOF'
    : > "$BOOTSTRAP_POISON_MARKER"
    EOF
    export BOOTSTRAP_POISON_MARKER="$TMPDIR/poison-profile-executed"
    BOOTSTRAP_NIX_PROFILE_SCRIPT="$TMPDIR/poison-profile" \
      bash "$bootstrap" plan --repo "$repo" --config "$host" >/dev/null
    test ! -e "$BOOTSTRAP_POISON_MARKER"

    # Rewritten rather than deleted. What this scenario actually proved was
    # hook gating on the mutating path - the poison-profile check above only
    # covers read-only `plan` - and its old evidence, a 69 exit naming the real
    # /etc/shells, was a side effect of bootstrap owning the login shell.
    # atyrode apply owns that now, so assert the property that survives: a
    # production apply ignores BOOTSTRAP_NIX_PROFILE_SCRIPT and runs to
    # completion. Linux only, because a production darwin apply would ignore
    # BOOTSTRAP_PROFILE_TARGET_ROOT too and repair the builder's real /etc.
    if [[ "$FAKE_SYSTEM" == *-linux ]]; then
      new_fixture production-hook-gating
      export PATH="$managed_tools:$base_path"
      BOOTSTRAP_NIX_PROFILE_SCRIPT="$TMPDIR/poison-profile" \
        bash "$bootstrap" apply --yes --repo "$repo" --config "$host" \
        > "$TMPDIR/production-hooks.out"
      test ! -e "$BOOTSTRAP_POISON_MARKER"
      test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
      test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
    fi

    # Repository identity, every class of dirt, and revision state are conservative.
    "$real_git" -C "$repo" remote set-url origin https://example.invalid/not-dotfiles.git
    expect_failure "$repo/install.sh" preflight --repo "$repo" --config "$host"
    "$real_git" -C "$repo" remote set-url origin https://github.com/atyrode/dotfiles.git
    "$real_git" -C "$repo" config url.file:///tmp/untrusted/.insteadOf https://github.com/
    expect_failure "$repo/install.sh" preflight --repo "$repo" --config "$host"
    "$real_git" -C "$repo" config --unset-all url.file:///tmp/untrusted/.insteadOf
    printf 'untracked\n' > "$repo/untracked"
    expect_failure "$repo/install.sh" plan --repo "$repo" --config "$host"
    "$repo/install.sh" plan --repo "$repo" --config "$host" --allow-dirty >/dev/null
    rm "$repo/untracked"
    printf 'changed\n' >> "$repo/flake.nix"
    "$real_git" -C "$repo" add flake.nix
    expect_failure "$repo/install.sh" plan --repo "$repo" --config "$host"
    "$real_git" -C "$repo" reset -q --hard HEAD
    printf 'local revision\n' > "$repo/local-revision"
    "$real_git" -C "$repo" add local-revision
    "$real_git" -C "$repo" commit -q -m local-revision
    expect_failure "$repo/install.sh" plan --repo "$repo" --config "$host"
    "$repo/install.sh" plan --repo "$repo" --config "$host" --allow-non-main >/dev/null
    "$real_git" -C "$repo" reset -q --hard origin/main
    "$real_git" -C "$repo" switch -q -c fixture
    expect_failure "$repo/install.sh" plan --repo "$repo" --config "$host"
    "$repo/install.sh" plan --repo "$repo" --config "$host" --allow-non-main >/dev/null
    "$real_git" -C "$repo" switch -q main
    "$real_git" -C "$repo" checkout -q --detach
    expect_failure "$repo/install.sh" plan --repo "$repo" --config "$host"
    "$repo/install.sh" plan --repo "$repo" --config "$host" --allow-non-main >/dev/null

    # A failed source update never reaches activation or writes the marker.
    new_fixture network-failure
    export PATH="$managed_tools:$base_path"
    export FAKE_GIT_FETCH_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --update --repo "$repo" --config "$host"
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
    test ! -e "$FAKE_LOG"
    test ! -e "$XDG_STATE_HOME"

    # A successful update re-enters the fetched bootstrap and activates it.
    new_fixture update-success
    export PATH="$managed_tools:$base_path"
    upstream="$TMPDIR/update-success/upstream"
    "$real_git" clone -q "$repo" "$upstream"
    "$real_git" -C "$upstream" config user.name fixture
    "$real_git" -C "$upstream" config user.email fixture@example.invalid
    printf 'updated\n' > "$upstream/update-marker"
    "$real_git" -C "$upstream" add update-marker
    "$real_git" -C "$upstream" commit -q -m update
    updated_revision="$("$real_git" -C "$upstream" rev-parse HEAD)"
    export FAKE_GIT_UPDATE_REPO="$upstream"
    "$repo/install.sh" apply --yes --update --repo "$repo" --config "$host" >/dev/null
    test "$("$real_git" -C "$repo" rev-parse HEAD)" = "$updated_revision"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"

    # A clean checkout parked on another branch is returned to main by the
    # same --update path instead of demanding a manual git checkout, and the
    # branch it left keeps every commit.
    new_fixture update-branch-return
    export PATH="$managed_tools:$base_path"
    upstream="$TMPDIR/update-branch-return/upstream"
    "$real_git" clone -q "$repo" "$upstream"
    "$real_git" -C "$upstream" config user.name fixture
    "$real_git" -C "$upstream" config user.email fixture@example.invalid
    printf 'updated\n' > "$upstream/update-marker"
    "$real_git" -C "$upstream" add update-marker
    "$real_git" -C "$upstream" commit -q -m update
    updated_revision="$("$real_git" -C "$upstream" rev-parse HEAD)"
    "$real_git" -C "$repo" checkout -q -b parked
    "$real_git" -C "$repo" commit -q --allow-empty -m 'local experiment'
    parked_revision="$("$real_git" -C "$repo" rev-parse HEAD)"
    export FAKE_GIT_UPDATE_REPO="$upstream"

    # Without --update the refusal still names the branch and moves nothing.
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F 'checkout is on parked, not main' "$TMPDIR/expected-failure.err" >/dev/null
    test "$("$real_git" -C "$repo" symbolic-ref --short HEAD)" = parked

    "$repo/install.sh" apply --yes --update --repo "$repo" --config "$host" \
      >/dev/null 2> "$TMPDIR/branch-return.err"
    grep -F 'moving the checkout from parked to main' "$TMPDIR/branch-return.err" >/dev/null
    test "$("$real_git" -C "$repo" symbolic-ref --short HEAD)" = main
    test "$("$real_git" -C "$repo" rev-parse HEAD)" = "$updated_revision"
    test "$("$real_git" -C "$repo" rev-parse parked)" = "$parked_revision"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
    # The fast-forward may have rewritten install.sh, so the run continues under
    # the new copy. Silently, that reads as the plan and its confirmation simply
    # appearing twice, and the operator answers the same question with no idea
    # why it was asked again.
    grep -F 'Restarting bootstrap under the updated source' "$TMPDIR/branch-return.err" >/dev/null
    grep -F 'it prints its plan and asks again' "$TMPDIR/branch-return.err" >/dev/null
    grep -E '^\$ bash .*install\.sh apply --repo .* --config ' "$TMPDIR/branch-return.err" >/dev/null

    # Download and integrity failures cannot execute the unverified installer.
    new_fixture download-failure
    export PATH="$fresh_tools:$base_path"
    export FAKE_CURL_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test ! -e "$FAKE_INSTALL_EXECUTED"
    grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

    new_fixture checksum-failure
    export PATH="$fresh_tools:$base_path"
    export FAKE_BAD_SHA=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test ! -e "$FAKE_INSTALL_EXECUTED"
    test ! -e "$HOME/.nix-profile/bin/nix"
    grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

    new_fixture partial-installer-failure
    export PATH="$fresh_tools:$base_path"
    export FAKE_INSTALLER_FAIL_AFTER_START=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test -e "$FAKE_INSTALL_EXECUTED"
    test ! -e "$HOME/.nix-profile/bin/nix"
    grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

    # An interrupted upstream install leaves `<rc>.backup-before-nix` files
    # that make every later attempt fail deep inside the installer. Bootstrap
    # repairs that itself rather than handing the operator instructions.
    new_fixture profile-backup-repair
    export PATH="$fresh_tools:$base_path"
    export BOOTSTRAP_PROFILE_TARGET_ROOT="$TMPDIR/profile-backup-repair/etcroot"
    etc="$BOOTSTRAP_PROFILE_TARGET_ROOT/etc"
    mkdir -p "$etc"

    # A backup identical to its target is what a completed install leaves
    # behind: never planned, never touched.
    printf 'settled\n' > "$etc/bash.bashrc"
    cp "$etc/bash.bashrc" "$etc/bash.bashrc.backup-before-nix"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/settled-plan.out"
    if grep -Fq 'Restore the pre-Nix shell rc file' "$TMPDIR/settled-plan.out"; then
      echo 'a settled backup was unexpectedly planned for restore' >&2
      exit 1
    fi

    # A deleted target and a target the interrupted install rewrote are both
    # planned, and plan still moves nothing.
    printf 'stock zshrc\n' > "$etc/zshrc.backup-before-nix"
    printf 'stock bashrc\n' > "$etc/bashrc.backup-before-nix"
    printf '# Nix\nstock bashrc\n' > "$etc/bashrc"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/repair-plan.out"
    grep -F 'Restore the pre-Nix shell rc file' "$TMPDIR/repair-plan.out" >/dev/null
    grep -F "$etc/zshrc" "$TMPDIR/repair-plan.out" >/dev/null
    grep -F "$etc/bashrc" "$TMPDIR/repair-plan.out" >/dev/null
    test -e "$etc/zshrc.backup-before-nix"
    test ! -e "$etc/zshrc"

    # apply restores both, keeps the rewritten file beside the restored
    # original instead of discarding it, and proceeds into the installer.
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" > "$TMPDIR/repair-apply.out"
    test "$(cat "$etc/zshrc")" = 'stock zshrc'
    test ! -e "$etc/zshrc.backup-before-nix"
    test "$(cat "$etc/bashrc")" = 'stock bashrc'
    test ! -e "$etc/bashrc.backup-before-nix"
    grep -Fxq '# Nix' "$etc/bashrc.nix-install-leftover"
    test "$(cat "$etc/bash.bashrc")" = settled
    test -e "$etc/bash.bashrc.backup-before-nix"
    grep -F "Restored $etc/zshrc" "$TMPDIR/repair-apply.out" >/dev/null
    test -e "$FAKE_INSTALL_EXECUTED"
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"

    # Fresh installation verifies the artifact, activates, verifies, and remains
    # idempotent on a repeated upgrade-style invocation.
    new_fixture fresh-success
    export PATH="$fresh_tools:$base_path"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" > "$TMPDIR/fresh.out"
    grep -F "exec $FAKE_EXPECTED_LOGIN_SHELL -l" "$TMPDIR/fresh.out" >/dev/null
    if grep -F 'exec zsh -l' "$TMPDIR/fresh.out" >/dev/null; then
      echo 'bootstrap emitted a PATH-dependent shell handoff' >&2
      exit 1
    fi
    test -e "$FAKE_INSTALL_EXECUTED"
    test "$(cat "$FAKE_INSTALL_ARGS")" = "$FAKE_EXPECTED_INSTALL_ARGS"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
    test "$(readlink "$HOME/.zshrc")" = /nix/store/fixture-home-manager-files/.zshrc
    test "$(readlink "$HOME/.zshenv")" = /nix/store/fixture-home-manager-files/.zshenv
    "$repo/install.sh" verify --repo "$repo" --config "$host" >/dev/null
    CODER_WORKSPACE_NAME=fixture \
      CODER_AGENT_URL=https://coder.example.invalid \
      FAKE_GH_AUTH=1 \
      "$repo/install.sh" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "development-${system}"
    grep -F -- "--git-auth-mode https-gh" "$FAKE_LOG" >/dev/null
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"

    # A failed activation leaves the interrupted-apply marker naming the
    # attempted configuration; the prior host state is untouched.
    new_fixture activation-failure
    export PATH="$managed_tools:$base_path"
    mkdir -p "$XDG_STATE_HOME/atyrode"
    printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    export FAKE_ACTIVATION_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

    # A post-activation verification failure also leaves the marker instead of
    # being mistaken for success.
    new_fixture verification-failure
    export PATH="$managed_tools:$base_path"
    mkdir -p "$XDG_STATE_HOME/atyrode"
    printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    export FAKE_VERIFY_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

    # Doctor's 69 is the opposite of the scenario above, and telling them apart
    # is the whole point: the machine activated, the receipt matches, and what
    # remains is drift that a later `atyrode apply` converges or that only the
    # operator can decide. Bootstrap therefore completes -- marker cleared, exit
    # zero -- and says what was found. Reported as a failure it became
    # [BOOT-E399], which sends the operator to the issue tracker and offers to
    # reset a Nix installation that was never broken.
    new_fixture doctor-findings-finish-the-bootstrap
    export PATH="$managed_tools:$base_path"
    export FAKE_DOCTOR_FINDINGS=1
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" \
      > "$TMPDIR/findings.out" 2> "$TMPDIR/findings.err"
    # On the operator's own stream, not inside the captured verification step:
    # a call to action that only a transcript ever sees is not a call to action.
    grep -qF 'Bootstrap complete, with findings for' "$TMPDIR/findings.out"
    grep -qF 'atyrode doctor' "$TMPDIR/findings.out"
    grep -qF 'exec ' "$TMPDIR/findings.out"
    # The two states this scenario exists to keep apart.
    ! grep -qF 'BOOT-E399' "$TMPDIR/findings.out" "$TMPDIR/findings.err"
    ! grep -qF 'recover --config' "$TMPDIR/findings.out" "$TMPDIR/findings.err"
    # An apply that finished must not look interrupted to the next run.
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
    unset FAKE_DOCTOR_FINDINGS

    # Every command that changes the machine is printed before it runs. A
    # bootstrap that mutates a machine silently is one an operator cannot audit
    # while it happens or reproduce afterwards, and the argv is shell-quoted so
    # the line can be pasted back verbatim.
    new_fixture bootstrap-shows-the-commands-it-runs
    export PATH="$managed_tools:$base_path"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" \
      > "$TMPDIR/visible.out" 2> "$TMPDIR/visible.err"
    # Either stream: a captured step replays its transcript on stdout, a
    # streamed one writes straight to stderr, and the operator reads both.
    cat "$TMPDIR/visible.out" "$TMPDIR/visible.err" > "$TMPDIR/visible.all"
    grep -qF "\$ nix run $repo#atyrode -- apply $host" "$TMPDIR/visible.all"
    grep -qF "\$ nix run $repo#atyrode -- doctor $host" "$TMPDIR/visible.all"

    # State and marker namespaces may not redirect writes through symlinks.
    new_fixture state-root-link
    export PATH="$managed_tools:$base_path"
    mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode"
    ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap"
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

    new_fixture atyrode-state-link
    export PATH="$managed_tools:$base_path"
    mkdir -p "$HOME/redirect" "$XDG_STATE_HOME"
    ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode"
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

    new_fixture interrupted-marker-link
    export PATH="$managed_tools:$base_path"
    mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode"
    ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/install-interrupted"
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

    # An abrupt interruption leaves the marker naming the attempted
    # configuration, plan warns about it without clearing it, and a
    # subsequent successful apply removes it.
    new_fixture interrupted
    export PATH="$managed_tools:$base_path"
    mkdir -p "$XDG_STATE_HOME/atyrode"
    printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    if BOOTSTRAP_FAILPOINT=before-activation \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'interruption failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    marker="$XDG_STATE_HOME/atyrode/install-interrupted"
    test -f "$marker"
    grep -Fxq "config=$host" "$marker"
    grep -Eq '^started=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    "$repo/install.sh" plan --repo "$repo" --config "$host" \
      > "$TMPDIR/interrupted-plan.out" 2> "$TMPDIR/interrupted-plan.err"
    grep -F "previous apply of $host" "$TMPDIR/interrupted-plan.err" >/dev/null
    grep -F "re-run: ./install.sh apply --config $host" \
      "$TMPDIR/interrupted-plan.err" >/dev/null
    test -f "$marker"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test ! -e "$marker"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"

    # A dead nix-darwin generation leaves /etc links resolving into a store
    # that no longer exists, at every depth: the CA bundle Nix reads for its
    # trust anchors is nested three levels down. They are removed, links this
    # toolchain does not own are left alone at every depth too, and the undo
    # journal can put every one of them back.
    darwin_fixture darwin-etc-link-repair
    export PATH="$fresh_tools:$base_path"
    ln -s /nix/store/0000000000000000000000000000000-etc "$etc/static"
    ln -s /etc/static/bashrc "$etc/bashrc"
    ln -s /Volumes/MountsLater/thing "$etc/unrelated"
    printf 'real\n' > "$etc/zshrc"
    mkdir -p "$etc/ssl/certs"
    ln -s /etc/static/ssl/certs/ca-certificates.crt "$etc/ssl/certs/ca-certificates.crt"
    ln -s /opt/elsewhere/foreign.crt "$etc/ssl/certs/foreign.crt"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-link-plan.out"
    grep -F "$etc/static" "$TMPDIR/etc-link-plan.out" >/dev/null
    grep -F "$etc/bashrc" "$TMPDIR/etc-link-plan.out" >/dev/null
    grep -F "$etc/ssl/certs/ca-certificates.crt" "$TMPDIR/etc-link-plan.out" >/dev/null
    grep -Fq "$etc/unrelated" "$TMPDIR/etc-link-plan.out" && exit 1
    grep -Fq "$etc/ssl/certs/foreign.crt" "$TMPDIR/etc-link-plan.out" && exit 1
    # plan is read-only: every link is still exactly as it was.
    test -L "$etc/static"
    test -L "$etc/bashrc"
    test -L "$etc/ssl/certs/ca-certificates.crt"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test ! -e "$etc/static" && test ! -L "$etc/static"
    test ! -e "$etc/bashrc" && test ! -L "$etc/bashrc"
    test ! -L "$etc/ssl/certs/ca-certificates.crt"
    # A dangling link bootstrap does not own survives untouched at any depth,
    # and so does a real file.
    test -L "$etc/unrelated"
    test -L "$etc/ssl/certs/foreign.crt"
    test -f "$etc/zshrc"
    undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
    grep -F "ln -s '/etc/static/bashrc' '$etc/bashrc'" "$undo" >/dev/null
    grep -F "removed dangling $etc/static" "$undo" >/dev/null
    grep -F "ln -s '/etc/static/ssl/certs/ca-certificates.crt' '$etc/ssl/certs/ca-certificates.crt'" \
      "$undo" >/dev/null

    # The /etc sweep repairs Nix itself, not the installer, so it must run
    # when Nix is already installed. That is the machine that most needs it:
    # a dangling CA bundle stops an installed Nix from verifying TLS, and
    # gating the sweep on Nix being absent leaves it unable to repair itself.
    darwin_fixture darwin-etc-link-repair-with-nix
    export PATH="$managed_tools:$base_path"
    mkdir -p "$etc/ssl/certs"
    ln -s /nix/store/0000000000000000000000000000000-etc/ca.crt \
      "$etc/ssl/certs/ca-certificates.crt"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-nix-plan.out"
    grep -F "$etc/ssl/certs/ca-certificates.crt" "$TMPDIR/etc-nix-plan.out" >/dev/null
    # The installer is not planned: Nix is present and stays present.
    grep -F 'Reuse the installed Nix command' "$TMPDIR/etc-nix-plan.out" >/dev/null
    test -L "$etc/ssl/certs/ca-certificates.crt"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test ! -L "$etc/ssl/certs/ca-certificates.crt"
    test ! -e "$FAKE_INSTALL_EXECUTED"
    # No CA bundle in the profile, so removal is the whole repair here: there
    # is nothing to restore the path from and nothing is invented.
    test ! -e "$etc/ssl/certs/ca-certificates.crt"

    # Removing the dangling anchor is not the end of it. Whatever named that
    # path still names it, so the file is merely absent and Nix keeps failing
    # on it - the state this machine was left in after the sweep worked. Each
    # namer is covered because each one is a different way to be wrong.
    trust_anchor_case() {
      darwin_fixture "$1"
      export PATH="$managed_tools:$base_path"
      bundle="$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
      mkdir -p "$(dirname "$bundle")" "$etc/ssl/certs"
      printf 'real anchors\n' > "$bundle"
      anchor="$etc/ssl/certs/ca-certificates.crt"
    }

    # Named by the environment: a login shell started under the dead
    # generation keeps exporting the path long after the store is collected.
    trust_anchor_case darwin-trust-anchor-env
    export NIX_SSL_CERT_FILE="$anchor"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-env.out"
    grep -F "Restore the TLS trust anchor" "$TMPDIR/anchor-env.out" >/dev/null
    grep -F "$anchor (named by NIX_SSL_CERT_FILE)" "$TMPDIR/anchor-env.out" >/dev/null
    test ! -e "$anchor"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test -L "$anchor" && test -e "$anchor"
    test "$(readlink "$anchor")" = "$bundle"
    grep -F "rm -f '$anchor'" "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null
    # Idempotent: the anchor now resolves, so a second run plans nothing.
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-again.out"
    grep -Fq 'Restore the TLS trust anchor' "$TMPDIR/anchor-again.out" && exit 1
    unset NIX_SSL_CERT_FILE

    # Named by /etc/nix/nix.conf, and still a dangling link this toolchain
    # owns: the sweep removes it and the restore puts a working file back, in
    # that order, so the machine ends with a resolving anchor.
    trust_anchor_case darwin-trust-anchor-conf
    mkdir -p "$etc/nix"
    printf 'ssl-cert-file = %s\n' "$anchor" > "$etc/nix/nix.conf"
    ln -s /nix/store/0000000000000000000000000000000-etc/ca.crt "$anchor"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-conf.out"
    grep -F "Remove links a previous nix-darwin left" "$TMPDIR/anchor-conf.out" >/dev/null
    grep -F "$anchor (named by $etc/nix/nix.conf)" "$TMPDIR/anchor-conf.out" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(readlink "$anchor")" = "$bundle"

    # Named by the nix-daemon launchd plist: the daemon, not the client, is
    # what fetches from the binary cache, so its environment is authoritative
    # even when the operator's shell says nothing.
    trust_anchor_case darwin-trust-anchor-plist
    plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    mkdir -p "$(dirname "$plist")"
    printf '<dict><key>NIX_SSL_CERT_FILE</key><string>%s</string></dict>\n' "$anchor" > "$plist"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-plist.out"
    grep -F "$anchor (named by $plist)" "$TMPDIR/anchor-plist.out" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(readlink "$anchor")" = "$bundle"

    # Three ways to be none of bootstrap's business: an anchor that is a usable
    # bundle, one kept outside /etc, and a dangling one this toolchain does not
    # own.
    trust_anchor_case darwin-trust-anchor-untouched
    printf -- '-----BEGIN CERTIFICATE-----\noperator anchors\n' > "$anchor"
    export NIX_SSL_CERT_FILE="$anchor"
    export SSL_CERT_FILE="$TMPDIR/elsewhere/ca.pem"
    mkdir -p "$etc/ssl/other"
    ln -s /opt/elsewhere/foreign.crt "$etc/ssl/other/foreign.crt"
    mkdir -p "$etc/nix"
    printf 'ssl-cert-file = %s\n' "$etc/ssl/other/foreign.crt" > "$etc/nix/nix.conf"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-untouched.out"
    grep -Fq 'Restore the TLS trust anchor' "$TMPDIR/anchor-untouched.out" && exit 1
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    grep -F 'operator anchors' "$anchor" >/dev/null
    test ! -L "$anchor"
    test -L "$etc/ssl/other/foreign.crt"
    test ! -e "$TMPDIR/elsewhere/ca.pem"
    unset NIX_SSL_CERT_FILE SSL_CERT_FILE

    # Nix does not look for this file, it loads it. A present but unparseable
    # bundle fails every download with the same error naming the same path as a
    # missing one - and nothing needs to name the path for Nix to read it, so
    # this state has no namer at all. Reported BOOT-E399 on the real machine
    # because detection asked whether the path resolved, not whether it worked.
    trust_anchor_case darwin-trust-anchor-unusable
    : > "$anchor"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-unusable.out"
    grep -F "$anchor (named by the path Nix probes by default)" \
      "$TMPDIR/anchor-unusable.out" >/dev/null
    test -f "$anchor"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(readlink "$anchor")" = "$bundle"
    # The unusable original is archived, and the undo journal puts it back.
    undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
    grep -F "archived unusable trust anchor $anchor" "$undo" >/dev/null
    test -n "$(find "$XDG_STATE_HOME/atyrode/bootstrap/repairs" -name 'ca-bundle.*' -print -quit)"

    # A launchd plist is routinely stored as binary, where the path inside is
    # not greppable text and only plutil can read it out.
    trust_anchor_case darwin-trust-anchor-binary-plist
    plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    mkdir -p "$(dirname "$plist")"
    { printf 'bplist00\n'
      printf '<dict><key>NIX_SSL_CERT_FILE</key><string>%s</string></dict>\n' "$anchor" |
        ${pkgs.coreutils}/bin/base64
    } > "$plist"
    # The path is genuinely unreadable as text; only decoding finds it.
    grep -Fq "$anchor" "$plist" && exit 1
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-bplist.out"
    grep -F "$anchor (named by $plist)" "$TMPDIR/anchor-bplist.out" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(readlink "$anchor")" = "$bundle"

    # A named anchor that is merely absent is classified, not shrugged at: this
    # exact state reported BOOT-E399 with a remedy that could never fire.
    trust_anchor_case darwin-trust-anchor-code
    export NIX_SSL_CERT_FILE="$anchor"
    expect_failure "$repo/install.sh" verify --repo "$repo" --config "$host"
    grep -F '[BOOT-E301]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F "named by NIX_SSL_CERT_FILE" "$TMPDIR/expected-failure.err" >/dev/null
    grep -F 'it restores that file' "$TMPDIR/expected-failure.err" >/dev/null
    unset NIX_SSL_CERT_FILE

    # An fstab entry naming a volume that no longer resolves is dropped, and
    # the file it came from is archived first so the edit is reversible.
    darwin_fixture darwin-fstab-repair
    export PATH="$fresh_tools:$base_path"
    printf 'Nix Store\tdisk3s7\tLIVE-UUID\n' > "$FAKE_VOLUMES"
    printf 'UUID=DEAD-UUID /nix apfs rw,noauto,nobrowse,nosuid,noatime,owners\n' \
      > "$etc/fstab"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/fstab-plan.out"
    grep -F "Drop the dead /nix entry from $etc/fstab" "$TMPDIR/fstab-plan.out" >/dev/null
    test -f "$etc/fstab"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    # macOS ships without /etc/fstab, so an emptied file is removed outright.
    test ! -e "$etc/fstab"
    archive="$(find "$XDG_STATE_HOME/atyrode/bootstrap/repairs" -name 'fstab.*' -print -quit)"
    grep -F 'UUID=DEAD-UUID /nix apfs' "$archive" >/dev/null

    # An orphaned Nix Store volume is renamed, never deleted: the installer
    # finds volumes by label, so a rename is enough to route it onto its
    # fresh-create path, and the data stays on disk.
    darwin_fixture darwin-orphaned-volume-repair
    export PATH="$fresh_tools:$base_path"
    printf 'Nix Store\tdisk3s7\tSTALE-UUID\n' > "$FAKE_VOLUMES"
    # The fstab line names the volume about to be renamed. A rename keeps the
    # UUID, so resolvability alone would not catch it; it must still be planned.
    printf 'UUID=STALE-UUID /nix apfs rw,noauto,nobrowse,nosuid,noatime,owners\n' \
      > "$etc/fstab"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/volume-plan.out"
    grep -F 'Retire the orphaned Nix Store volume disk3s7' "$TMPDIR/volume-plan.out" >/dev/null
    grep -F 'nothing on it is deleted' "$TMPDIR/volume-plan.out" >/dev/null
    grep -F "Drop the dead /nix entry from $etc/fstab" "$TMPDIR/volume-plan.out" >/dev/null
    grep -F 'Nix Store	disk3s7' "$FAKE_VOLUMES" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    # Same device, same UUID, new label: nothing was destroyed.
    grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID	" "$FAKE_VOLUMES" >/dev/null
    undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
    grep -F "diskutil rename 'disk3s7' 'Nix Store'" "$undo" >/dev/null

    # An unmounted volume is not a hypothetical: recovery unmounts to free
    # /nix, so the very next run meets one. diskutil renames through the
    # mounted filesystem, so the rename must mount it first and leave it
    # unmounted afterwards - occupying /nix would block the installer.
    darwin_fixture darwin-unmounted-volume-repair
    export PATH="$fresh_tools:$base_path"
    printf 'Nix Store\tdisk3s7\tSTALE-UUID\tno\n' > "$FAKE_VOLUMES"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID	no	$" "$FAKE_VOLUMES" >/dev/null
    test -e "$FAKE_INSTALL_EXECUTED"

    # The installer encrypts the volume it creates and keeps the passphrase in
    # the System keychain, so an unmounted one is also locked. Unlocking with
    # that passphrase is what keeps this repair non-destructive.
    darwin_fixture darwin-locked-volume-repair
    export PATH="$fresh_tools:$base_path"
    export FAKE_VOLUME_PASSPHRASE=correct-horse
    export FAKE_KEYCHAIN_UUID=STALE-UUID
    printf 'Nix Store\tdisk3s7\tSTALE-UUID\tno\tlocked\n' > "$FAKE_VOLUMES"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID	no	$" "$FAKE_VOLUMES" >/dev/null
    test -e "$FAKE_INSTALL_EXECUTED"
    grep -F "diskutil rename 'disk3s7' 'Nix Store'" \
      "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null
    unset FAKE_VOLUME_PASSPHRASE FAKE_KEYCHAIN_UUID

    # No key means no mount, and no mount means no rename. Leaving it labelled
    # Nix Store routes the installer onto the path that crashes, so it is
    # deleted - the store-database check already proved no live install is on
    # it, and a Nix store re-downloads. The journal records that this one does
    # not undo.
    darwin_fixture darwin-locked-volume-no-key
    export PATH="$fresh_tools:$base_path"
    printf 'Nix Store\tdisk3s7\tSTALE-UUID\tno\tlocked\n' > "$FAKE_VOLUMES"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/locked-plan.out"
    grep -F 'it is deleted instead' "$TMPDIR/locked-plan.out" >/dev/null
    # Deleting a volume is the one irreversible repair, so the run must say
    # what it observed rather than only that it deleted something.
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" \
      > "$TMPDIR/locked-apply.out"
    grep -F 'Reason:' "$TMPDIR/locked-apply.out" >/dev/null
    grep -F 'no passphrase for STALE-UUID in the System keychain' \
      "$TMPDIR/locked-apply.out" >/dev/null
    test ! -s "$FAKE_VOLUMES"
    test -e "$FAKE_INSTALL_EXECUTED"
    undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
    grep -F 'deleted the locked Nix Store volume disk3s7' "$undo" >/dev/null
    grep -F 'undo: none:' "$undo" >/dev/null

    # A volume carrying a live store is in use, not orphaned, and is never
    # touched however the rest of the machine looks.
    darwin_fixture darwin-live-volume-untouched
    export PATH="$fresh_tools:$base_path"
    printf 'Nix Store\tdisk3s7\tLIVE-UUID\n' > "$FAKE_VOLUMES"
    mkdir -p "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db"
    : > "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db/db.sqlite"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/live-volume-plan.out"
    grep -Fq 'Rename the orphaned' "$TMPDIR/live-volume-plan.out" && exit 1
    grep -F 'Nix Store	disk3s7' "$FAKE_VOLUMES" >/dev/null

    # The upstream installer appends its block to shell rc files nix-darwin
    # manages, and nix-darwin aborts activation rather than overwrite content
    # it does not recognise. Moving them aside is what nix-darwin's own etc
    # activation does to a conflicting file, so the end state is the one a
    # successful activation produces - reached before the abort, not after it.
    darwin_fixture darwin-etc-profile-conflict
    export PATH="$managed_tools:$base_path"
    # The block the upstream installer appends, marker line and all.
    nix_block='# Nix\nif [ -e "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh" ]; then\n  . "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"\nfi\n# End Nix\n'
    printf "stock zshrc\n$nix_block" > "$etc/zshrc"
    printf "stock bashrc\n$nix_block" > "$etc/bashrc"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-profile-plan.out"
    grep -F "$etc/zshrc" "$TMPDIR/etc-profile-plan.out" >/dev/null
    grep -F 'before-nix-darwin' "$TMPDIR/etc-profile-plan.out" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test ! -e "$etc/zshrc"
    test ! -e "$etc/bashrc"
    # Moved, not rewritten: the content is the file the installer left.
    grep -F 'stock zshrc' "$etc/zshrc.before-nix-darwin" >/dev/null
    grep -F '# End Nix' "$etc/zshrc.before-nix-darwin" >/dev/null
    undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
    grep -F "mv '$etc/zshrc.before-nix-darwin' '$etc/zshrc'" "$undo" >/dev/null

    # A path nix-darwin already owns resolves into /etc/static and is left
    # alone, and a file this toolchain did not write is not bootstrap's to
    # move however much it looks like a shell rc file.
    darwin_fixture darwin-etc-profile-untouched
    export PATH="$managed_tools:$base_path"
    mkdir -p "$etc/static"
    printf 'managed\n# End Nix\n' > "$etc/static/zshrc"
    ln -s "$etc/static/zshrc" "$etc/zshrc"
    printf 'hand written, no marker\n' > "$etc/bashrc"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/etc-untouched-plan.out"
    grep -Fq 'before-nix-darwin' "$TMPDIR/etc-untouched-plan.out" && exit 1
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test -L "$etc/zshrc"
    test ! -e "$etc/zshrc.before-nix-darwin"
    test "$(cat "$etc/bashrc")" = 'hand written, no marker'
    test ! -e "$etc/bashrc.before-nix-darwin"

    # A backup already at that name is the one an earlier nix-darwin generation
    # made, and it holds the pre-nix-darwin original. Writing over it would
    # discard the older copy to keep the newer one, so the installer's file is
    # archived instead and the original stays where it is.
    darwin_fixture darwin-etc-profile-backup-collision
    export PATH="$managed_tools:$base_path"
    printf 'the real original\n' > "$etc/zshrc.before-nix-darwin"
    printf 'installer wrote this\n# End Nix\n' > "$etc/zshrc"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test ! -e "$etc/zshrc"
    test "$(cat "$etc/zshrc.before-nix-darwin")" = 'the real original'
    archive="$(find "$XDG_STATE_HOME/atyrode/bootstrap/repairs" -name 'zshrc.*' -print -quit)"
    grep -F 'installer wrote this' "$archive" >/dev/null
    grep -F "cp '$archive' '$etc/zshrc'" \
      "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null

    # A file bootstrap did not write is not bootstrap's to move, so activation
    # still refuses - and the refusal names the file and the exact command
    # that clears it, rather than costing a round trip as an unclassified
    # code. The transcript arrives indented under nh's error, which is the
    # shape the parser has to survive.
    darwin_fixture darwin-etc-conflict-not-ours
    export PATH="$managed_tools:$base_path"
    printf 'a file the operator wrote\n' > "$etc/zshrc"
    FAKE_ETC_CONFLICTS="$etc/zshrc" \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E303]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F "sudo mv $etc/zshrc $etc/zshrc.before-nix-darwin" \
      "$TMPDIR/expected-failure.err" >/dev/null
    # Refusing is not repairing: the file it named is still exactly there.
    test "$(cat "$etc/zshrc")" = 'a file the operator wrote'

    # A path named in a transcript is a claim; a path that is gone is not a
    # state, and reporting it as one sends the operator after a file that is
    # not there.
    darwin_fixture darwin-etc-conflict-absent
    export PATH="$managed_tools:$base_path"
    FAKE_ETC_CONFLICTS="$etc/zshrc" \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E399]' "$TMPDIR/expected-failure.err" >/dev/null

    # An upstream installer failure is classified into a code that names the
    # repair, and an unrecognised one reports the transcript instead of a
    # bare exit status.
    darwin_fixture darwin-installer-failure-codes
    export PATH="$fresh_tools:$base_path"
    FAKE_INSTALLER_FAIL_MESSAGE='touch: /etc/bashrc: No such file or directory' \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E201]' "$TMPDIR/expected-failure.err" >/dev/null
    FAKE_INSTALLER_FAIL_MESSAGE='something nobody has seen before' \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E299]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F 'nix-installer.log' "$TMPDIR/expected-failure.err" >/dev/null

    # A managed step runs Nix, so it fails whenever Nix cannot reach the cache.
    # A dangling CA bundle is the state that causes it, and it is re-derived at
    # failure time rather than parsed out of the error prose.
    darwin_fixture darwin-managed-step-codes
    export PATH="$managed_tools:$base_path"
    mkdir -p "$etc/ssl/certs" "$HOME/.nix-profile/bin"
    # Not owned by this toolchain, so the sweep correctly leaves it in place
    # and activation is the first thing to trip over it.
    ln -s /opt/elsewhere/ca.crt "$etc/ssl/certs/ca-certificates.crt"
    FAKE_ACTIVATION_FAIL=1 \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E302]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F "$etc/ssl/certs/ca-certificates.crt" "$TMPDIR/expected-failure.err" >/dev/null
    test -L "$etc/ssl/certs/ca-certificates.crt"

    # The same state, but owned: verify runs no repairs, so it is the phase
    # that can still meet a stale link and must name it rather than exit bare.
    rm "$etc/ssl/certs/ca-certificates.crt"
    ln -s /nix/store/0000000000000000000000000000000-etc/ca.crt \
      "$etc/ssl/certs/ca-certificates.crt"
    expect_failure "$repo/install.sh" verify --repo "$repo" --config "$host"
    grep -F '[BOOT-E301]' "$TMPDIR/expected-failure.err" >/dev/null

    # No CA problem: the failure is unrecognised, says so with the log, and
    # names the exit so an unclassified state is never a dead end.
    rm "$etc/ssl/certs/ca-certificates.crt"
    FAKE_ACTIVATION_FAIL=1 \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E399]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F '  log: ' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F "./install.sh recover --config $host" "$TMPDIR/expected-failure.err" >/dev/null

    # A configuration that fails to build is not a broken machine. This landed
    # in the unrecognised bucket and offered to reset a perfectly healthy Nix
    # installation -- the same wrong remedy the doctor-69 case above already
    # had to be taught once, reached by a different route.
    FAKE_BUILD_FAIL=1 \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E304]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F 'darwin-system-26.11' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F 'this machine is unchanged' "$TMPDIR/expected-failure.err" >/dev/null
    ! grep -qF './install.sh recover' "$TMPDIR/expected-failure.err"

    # Recovery is the exit for a state with no repair. It resets what a dead
    # generation owns - the daemon, /etc/nix, the store volume - and installs
    # Nix fresh, without deleting anything it cannot put back.
    darwin_fixture darwin-recover
    export PATH="$managed_tools:$base_path"
    export FAKE_LAUNCHCTL_LOG="$TMPDIR/darwin-recover/launchctl.log"
    plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    mkdir -p "$(dirname "$plist")" "$etc/nix"
    printf '<dict><key>Label</key><string>org.nixos.nix-daemon</string></dict>\n' > "$plist"
    printf 'ssl-cert-file = %s/ssl/certs/ca-certificates.crt\n' "$etc" > "$etc/nix/nix.conf"
    printf 'Nix Store\tdisk3s7\tLIVE-UUID\n' > "$FAKE_VOLUMES"
    mkdir -p "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db"
    : > "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db/db.sqlite"
    # Recovery is destructive enough to require saying so out loud: it prints
    # the plan, then refuses to touch anything without an explicit answer.
    if "$repo/install.sh" recover --repo "$repo" --config "$host" \
      > "$TMPDIR/recover-plan.out" 2> "$TMPDIR/recover-plan.err"; then
      echo 'recover proceeded without confirmation' >&2
      exit 1
    fi
    grep -F 'Recovery plan' "$TMPDIR/recover-plan.out" >/dev/null
    grep -F 'nothing on it is deleted' "$TMPDIR/recover-plan.out" >/dev/null
    grep -F 'requires an interactive terminal' "$TMPDIR/recover-plan.err" >/dev/null
    # Nothing moved: a live install is still exactly as it was.
    test -f "$plist"
    test -f "$etc/nix/nix.conf"
    test ! -e "$FAKE_INSTALL_EXECUTED"

    "$repo/install.sh" recover --yes --repo "$repo" --config "$host" >/dev/null
    grep -Fx 'system/org.nixos.nix-daemon' "$FAKE_LAUNCHCTL_LOG" >/dev/null
    test ! -e "$plist"
    test ! -e "$etc/nix"
    # Renamed, not deleted: same device, same UUID, and the data is still there.
    grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	LIVE-UUID	" "$FAKE_VOLUMES" >/dev/null
    # Nix was present, and recovery reinstalls it anyway - that is the point.
    test -e "$FAKE_INSTALL_EXECUTED"
    # An undo command is only worth the file it restores from, so assert the
    # archive exists and still holds what was removed.
    repairs="$XDG_STATE_HOME/atyrode/bootstrap/repairs"
    undo="$repairs/undo.log"
    grep -F "cp '$repairs/nix-daemon.plist." "$undo" >/dev/null
    grep -F 'org.nixos.nix-daemon' \
      "$(find "$repairs" -name 'nix-daemon.plist.*' -print -quit)" >/dev/null
    grep -F "removed $etc/nix" "$undo" >/dev/null
    grep -F 'ssl-cert-file' \
      "$(find "$repairs" -name 'etc-nix.*' -print -quit)/nix.conf" >/dev/null
    grep -F "diskutil rename 'disk3s7' 'Nix Store'" "$undo" >/dev/null
    unset FAKE_LAUNCHCTL_LOG

    # An already-unloaded daemon is the state recovery converges on, so a
    # non-zero bootout must not fail the run.
    darwin_fixture darwin-recover-unloaded-daemon
    export PATH="$managed_tools:$base_path"
    export FAKE_LAUNCHCTL_LOADED=0
    plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    mkdir -p "$(dirname "$plist")"
    printf '<dict/>\n' > "$plist"
    : > "$FAKE_VOLUMES"
    "$repo/install.sh" recover --yes --repo "$repo" --config "$host" >/dev/null
    test ! -e "$plist"
    unset FAKE_LAUNCHCTL_LOADED

    # On Linux the managed environment lives in /nix, so removing it is
    # destruction rather than recovery, and recovery refuses by name. The
    # platform is forced rather than inherited from the runner: taking it from
    # uname would assert nothing on the macOS job, which is the one job where
    # recovery is reachable.
    new_fixture recover-refuses-on-linux
    export PATH="$managed_tools:$base_path"
    export BOOTSTRAP_FORCE_SYSTEM=x86_64-linux
    expect_failure "$repo/install.sh" recover --yes --repo "$repo" --config "$host"
    grep -F 'is not a recovery' "$TMPDIR/expected-failure.err" >/dev/null

    # Capturing a managed step costs the conversation it was holding: the CLI
    # gates sudo, the vault, and every provisioning offer on stdin and stdout
    # both being a terminal. Where one is present bootstrap must hand the step
    # its own stdio and write no transcript, and the run log must say so, since
    # that file is the account of where the output went.
    new_fixture managed-step-streams-on-a-terminal
    export PATH="$managed_tools:$base_path"
    export BOOTSTRAP_TEST_TTY=1
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    log="$(find "$XDG_STATE_HOME/atyrode/bootstrap/logs" -name '*-apply.log' -print -quit)"
    grep -F 'activation streamed to the operator terminal' "$log" >/dev/null
    test ! -e "''${log%.log}-activation.log"

    # The same failure still gets a code without a transcript to read: the
    # states that classify from machine state are exactly the ones a terminal
    # cannot take away. The anchor is unowned so the sweep leaves it, which
    # makes activation the first step to trip over it.
    darwin_fixture managed-step-streams-and-still-classifies
    export PATH="$managed_tools:$base_path"
    export BOOTSTRAP_TEST_TTY=1
    mkdir -p "$etc/ssl/certs" "$HOME/.nix-profile/bin"
    ln -s /opt/elsewhere/ca.crt "$etc/ssl/certs/ca-certificates.crt"
    FAKE_ACTIVATION_FAIL=1 \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E302]' "$TMPDIR/expected-failure.err" >/dev/null
    log="$(find "$XDG_STATE_HOME/atyrode/bootstrap/logs" -name '*-apply.log' -print -quit)"
    test ! -e "''${log%.log}-activation.log"
    unset FAKE_ACTIVATION_FAIL

    # Without a terminal the transcript is the only account of the step, so it
    # is written and the classifier reads it. This is the contract the E303
    # scenarios above depend on; assert it directly rather than by their proxy.
    new_fixture managed-step-captures-without-a-terminal
    export PATH="$managed_tools:$base_path"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    log="$(find "$XDG_STATE_HOME/atyrode/bootstrap/logs" -name '*-apply.log' -print -quit)"
    test -f "''${log%.log}-activation.log"
    grep -F 'Verification passed' "''${log%.log}-verification.log" >/dev/null

    # Colour is a reading aid, never data. Every assertion in this file greps
    # plain text, and every operator who redirects a run reads plain text, so
    # the invariant is that a non-terminal run emits no escape byte at all.
    new_fixture plan-emits-no-escapes-off-a-terminal
    export PATH="$managed_tools:$base_path"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/plain.out" 2>&1
    grep -F 'Preflight passed' "$TMPDIR/plain.out" >/dev/null
    ! grep -q "$(printf '\033')" "$TMPDIR/plain.out"

    # And that the painting is real when a terminal is present, so the plain
    # case above is evidence of the gate rather than of dead code.
    new_fixture plan-paints-on-a-terminal
    export PATH="$managed_tools:$base_path"
    export BOOTSTRAP_TEST_COLOR=1
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/painted.out" 2>&1
    grep -q "$(printf '\033')" "$TMPDIR/painted.out"
    grep -F "$(printf '\033[1;32mPreflight passed\033[0m')" "$TMPDIR/painted.out" >/dev/null

    # NO_COLOR is honoured even where the stream would allow colour: it is the
    # operator's decision, not the terminal's.
    new_fixture no-color-is-honoured
    export PATH="$managed_tools:$base_path"
    NO_COLOR=1 "$repo/install.sh" plan --repo "$repo" --config "$host" \
      > "$TMPDIR/nocolor.out" 2>&1
    ! grep -q "$(printf '\033')" "$TMPDIR/nocolor.out"
    mkdir "$out"
  ''
