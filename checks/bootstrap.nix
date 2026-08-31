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

    cat > "$tool_root/sudo" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    [ "''${FAKE_SUDO_FAIL:-0}" != 1 ] || exit 77
    if [ "''${1:-}" = -- ]; then
      shift
    fi
    exec "$@"
    EOF

    cat > "$tool_root/gh" <<'EOF'
    #!${pkgs.runtimeShell}
    [ "$#" -eq 2 ] && [ "$1" = auth ] && [ "$2" = status ] || exit 64
    [ "''${FAKE_GH_AUTH:-0}" = 1 ]
    EOF

    cat > "$tool_root/chsh" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    [ "''${FAKE_CHSH_FAIL:-0}" != 1 ] || exit 78
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s)
          target="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    [ -n "$target" ] || exit 64
    printf '%s\n' "$target" > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
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
      *" -- doctor host "*)
        [ "''${FAKE_VERIFY_FAIL:-0}" != 1 ]
        ;;
      *" -- doctor system "*)
        current="$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE" 2>/dev/null || true)"
        if [ "$current" = "$FAKE_EXPECTED_LOGIN_SHELL" ] &&
          grep -Fqx -- "$FAKE_EXPECTED_LOGIN_SHELL" "$BOOTSTRAP_SHELLS_FILE"; then
          printf 'login-shell: ok — fixture account database matches managed Zsh\n'
          exit 0
        fi
        printf 'login-shell: incomplete — fixture account database or shell registry differs\n'
        exit 69
        ;;
      *) exit 64 ;;
    esac
    EOF

    # A volume table stands in for diskutil: "name<TAB>device<TAB>uuid" per
    # line. Only the two subcommands bootstrap uses are implemented, and
    # rename rewrites the table so a test can prove the volume survived.
    cat > "$tool_root/diskutil" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    table="''${FAKE_VOLUMES:-}"
    { [ -n "$table" ] && [ -f "$table" ]; } || exit 1
    tab="$(printf '\t')"
    case "''${1:-}" in
      info)
        while IFS="$tab" read -r name device uuid; do
          [ -n "$name" ] || continue
          if [ "$2" = "$name" ] || [ "$2" = "$device" ] || [ "$2" = "$uuid" ]; then
            printf '   Device Identifier:         %s\n' "$device"
            printf '   Volume Name:               %s\n' "$name"
            printf '   Volume UUID:               %s\n' "$uuid"
            exit 0
          fi
        done < "$table"
        exit 1
        ;;
      rename)
        : > "$table.next"
        while IFS="$tab" read -r name device uuid; do
          [ -n "$name" ] || continue
          if [ "$2" = "$device" ] || [ "$2" = "$name" ]; then
            printf '%s\t%s\t%s\n' "$3" "$device" "$uuid" >> "$table.next"
          else
            printf '%s\t%s\t%s\n' "$name" "$device" "$uuid" >> "$table.next"
          fi
        done < "$table"
        mv "$table.next" "$table"
        ;;
      *) exit 64 ;;
    esac
    EOF

    chmod +x \
      "$tool_root/git" \
      "$tool_root/curl" \
      "$tool_root/sha256sum" \
      "$tool_root/shasum" \
      "$tool_root/sudo" \
      "$tool_root/chsh" \
      "$tool_root/gh" \
      "$tool_root/tar" \
      "$tool_root/diskutil" \
      "$fake_installer_template" \
      "$fake_nix_template"
    for tool in git curl sha256sum shasum sudo chsh gh tar diskutil; do
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
      export BOOTSTRAP_ACCOUNT_SHELL_FILE="$TMPDIR/$fixture_name/account-shell"
      export BOOTSTRAP_SHELLS_FILE="$TMPDIR/$fixture_name/shells"
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
        CODER_AGENT_URL \
        CODER_WORKSPACE_NAME \
        FAKE_ACTIVATION_FAIL \
        FAKE_BAD_SHA \
        FAKE_CHSH_FAIL \
        FAKE_CURL_FAIL \
        FAKE_GH_AUTH \
        FAKE_GIT_FETCH_FAIL \
        FAKE_GIT_UPDATE_REPO \
        FAKE_INSTALLER_FAIL_AFTER_START \
        FAKE_INSTALLER_FAIL_MESSAGE \
        FAKE_SUDO_FAIL \
        FAKE_VERIFY_FAIL \
        FAKE_VOLUMES
      mkdir -p "$HOME" "$repo"
      printf '%s\n' "$FAKE_EXPECTED_LOGIN_SHELL" > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      printf '%s\n' "$FAKE_EXPECTED_LOGIN_SHELL" > "$BOOTSTRAP_SHELLS_FILE"
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
      printf '%s\n' "$FAKE_EXPECTED_LOGIN_SHELL" > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      printf '%s\n' "$FAKE_EXPECTED_LOGIN_SHELL" > "$BOOTSTRAP_SHELLS_FILE"
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

    # Production bootstrap also ignores the login-shell fixture hooks: with
    # the fixture files exported, a production Linux apply must consult the
    # real /etc/shells (absent in the sandbox) and report the system
    # prerequisite instead of consuming the fixtures the hooked script uses.
    if [[ "$FAKE_SYSTEM" == *-linux ]]; then
      new_fixture production-hook-gating
      export PATH="$managed_tools:$base_path"
      set +e
      bash "$bootstrap" apply --yes --repo "$repo" --config "$host" \
        > "$TMPDIR/production-hooks.out" 2> "$TMPDIR/production-hooks.err"
      production_status="$?"
      set -e
      test "$production_status" = 69
      grep -q '/etc/shells' "$TMPDIR/production-hooks.err"
      test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
      test -f "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
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
    if [[ "$FAKE_SYSTEM" == *-linux ]]; then
      printf '/bin/bash\n' > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      : > "$BOOTSTRAP_SHELLS_FILE"
      export SHELL="$FAKE_EXPECTED_LOGIN_SHELL"
    fi
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
    test "$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE")" = "$FAKE_EXPECTED_LOGIN_SHELL"
    test "$(grep -Fxc -- "$FAKE_EXPECTED_LOGIN_SHELL" "$BOOTSTRAP_SHELLS_FILE")" = 1
    unset SHELL

    # The conservative prerequisite marker is published before the
    # interrupted-apply marker clears. An interruption after that point
    # cannot make an unverified login-shell transition look ready.
    new_fixture login-shell-receipt-interruption
    export PATH="$managed_tools:$base_path"
    if BOOTSTRAP_FAILPOINT=after-login-shell-receipt \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'login-shell receipt failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
    test -f "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
    "$repo/install.sh" verify --repo "$repo" --config "$host" >/dev/null
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"

    # Unsafe marker types are rejected before any managed evaluation or
    # activation can begin.
    new_fixture login-shell-marker-link
    export PATH="$managed_tools:$base_path"
    mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap"
    ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test ! -e "$FAKE_LOG"

    new_fixture login-shell-marker-directory
    export PATH="$managed_tools:$base_path"
    mkdir -p "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test ! -e "$FAKE_LOG"

    # Linux login-shell ownership is a separate, recoverable prerequisite. A
    # privilege failure cannot roll back a completed Home Manager activation or
    # masquerade as a successful system-boundary transition.
    if [[ "$FAKE_SYSTEM" == *-linux ]]; then
      new_fixture login-shell-privilege-failure
      export PATH="$managed_tools:$base_path"
      printf '/bin/bash\n' > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      : > "$BOOTSTRAP_SHELLS_FILE"
      export FAKE_SUDO_FAIL=1
      set +e
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" \
        > "$TMPDIR/login-shell-privilege.out" \
        2> "$TMPDIR/login-shell-privilege.err"
      login_shell_status="$?"
      set -e
      test "$login_shell_status" = 69
      test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
      test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
      test -f "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
      test "$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE")" = /bin/bash
      unset FAKE_SUDO_FAIL
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
      test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
      test "$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE")" = "$FAKE_EXPECTED_LOGIN_SHELL"
      test "$(grep -Fxc -- "$FAKE_EXPECTED_LOGIN_SHELL" "$BOOTSTRAP_SHELLS_FILE")" = 1

      # A chsh-specific failure has the same recovery contract after the shell
      # has already been registered in /etc/shells.
      new_fixture login-shell-chsh-failure
      export PATH="$managed_tools:$base_path"
      printf '/bin/bash\n' > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      export FAKE_CHSH_FAIL=1
      set +e
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" \
        > "$TMPDIR/login-shell-chsh.out" \
        2> "$TMPDIR/login-shell-chsh.err"
      login_shell_status="$?"
      set -e
      test "$login_shell_status" = 69
      test -f "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
      test "$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE")" = /bin/bash
      unset FAKE_CHSH_FAIL
      "$repo/install.sh" verify --repo "$repo" --config "$host" >/dev/null 2>&1 && exit 1
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
      test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
      test "$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE")" = "$FAKE_EXPECTED_LOGIN_SHELL"
      test "$(grep -Fxc -- "$FAKE_EXPECTED_LOGIN_SHELL" "$BOOTSTRAP_SHELLS_FILE")" = 1
    fi

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

    # Three ways to be none of bootstrap's business: an anchor that resolves,
    # one kept outside /etc, and a dangling one this toolchain does not own.
    trust_anchor_case darwin-trust-anchor-untouched
    printf 'operator anchors\n' > "$anchor"
    export NIX_SSL_CERT_FILE="$anchor"
    export SSL_CERT_FILE="$TMPDIR/elsewhere/ca.pem"
    mkdir -p "$etc/ssl/other"
    ln -s /opt/elsewhere/foreign.crt "$etc/ssl/other/foreign.crt"
    mkdir -p "$etc/nix"
    printf 'ssl-cert-file = %s\n' "$etc/ssl/other/foreign.crt" > "$etc/nix/nix.conf"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/anchor-untouched.out"
    grep -Fq 'Restore the TLS trust anchor' "$TMPDIR/anchor-untouched.out" && exit 1
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(cat "$anchor")" = 'operator anchors'
    test -L "$etc/ssl/other/foreign.crt"
    test ! -e "$TMPDIR/elsewhere/ca.pem"
    unset NIX_SSL_CERT_FILE SSL_CERT_FILE

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
    grep -F 'Rename the orphaned Nix Store volume disk3s7' "$TMPDIR/volume-plan.out" >/dev/null
    grep -F 'nothing on it is deleted' "$TMPDIR/volume-plan.out" >/dev/null
    grep -F "Drop the dead /nix entry from $etc/fstab" "$TMPDIR/volume-plan.out" >/dev/null
    grep -F 'Nix Store	disk3s7' "$FAKE_VOLUMES" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    # Same device, same UUID, new label: nothing was destroyed.
    grep -E '^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	STALE-UUID$' "$FAKE_VOLUMES" >/dev/null
    undo="$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log"
    grep -F "diskutil rename 'disk3s7' 'Nix Store'" "$undo" >/dev/null

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

    # No CA problem: the failure is unrecognised, and says so with the log.
    rm "$etc/ssl/certs/ca-certificates.crt"
    FAKE_ACTIVATION_FAIL=1 \
      expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F '[BOOT-E399]' "$TMPDIR/expected-failure.err" >/dev/null
    grep -F '  log: ' "$TMPDIR/expected-failure.err" >/dev/null

    mkdir "$out"
  ''
