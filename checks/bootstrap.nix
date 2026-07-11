{ pkgs }:

let
  system = pkgs.stdenv.hostPlatform.system;
  expectedHash =
    {
      "aarch64-darwin" = "1e18301c4ea78c667f2753159156b5bdb899993720e8aa7bcca97e8312d3d6b";
      "x86_64-darwin" = "bf3dadfd65be182ad3141b1224bbc82e0f2a61d4f36781938b5e6ede029c2a37";
      "aarch64-linux" = "1cee64ae7a02330c6421924c28f597c41813f2214ff108622087d8056378b088";
      "x86_64-linux" = "eafe5042404e818505e28c5ca3d0885f3ec45c31f955489a25bb38258f87560ef";
    }
    .${system};
in
pkgs.runCommand "check-bootstrap-${system}"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
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
    migration=${../scripts/bootstrap-migrate.sh}
    real_git=${pkgs.git}/bin/git
    base_path="$PATH"
    host="alex-${system}"
    tool_root="$TMPDIR/tools"
    fresh_tools="$tool_root/fresh"
    managed_tools="$tool_root/managed"
    fake_nix_template="$tool_root/fake-nix"
    fake_installer_template="$tool_root/fake-installer"

    bash -n "$bootstrap"
    bash -n "$migration"
    shellcheck -x "$bootstrap" "$migration"
    if grep -Eq 'mapfile|declare -A|local -n|\[\[ -v |\$\{[^}]+,,\}|flock|stat -c' \
      "$bootstrap" "$migration"; then
      echo 'bootstrap uses a construct unavailable before Nix or on Bash 3.2' >&2
      exit 1
    fi

    mkdir -p "$fresh_tools" "$managed_tools"
    grep -Fqx 'readonly BOOTSTRAP_TEST_HOOKS=0' "$bootstrap"
    grep -Fqx 'readonly BOOTSTRAP_MIGRATION_TEST_HOOKS=0' "$migration"
    production_migration="$migration"
    cp "$migration" "$tool_root/bootstrap-migrate-test"
    substituteInPlace "$tool_root/bootstrap-migrate-test" \
      --replace-fail 'readonly BOOTSTRAP_MIGRATION_TEST_HOOKS=0' \
      'readonly BOOTSTRAP_MIGRATION_TEST_HOOKS=1'
    migration="$tool_root/bootstrap-migrate-test"

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

    chmod +x \
      "$tool_root/git" \
      "$tool_root/curl" \
      "$tool_root/sha256sum" \
      "$tool_root/shasum" \
      "$tool_root/sudo" \
      "$tool_root/chsh" \
      "$tool_root/tar" \
      "$fake_installer_template" \
      "$fake_nix_template"
    for tool in git curl sha256sum shasum sudo chsh tar; do
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
      export FAKE_NIX_TEMPLATE="$fake_nix_template"
      export FAKE_INSTALLER_TEMPLATE="$fake_installer_template"
      export FAKE_SHA256SUM="$tool_root/sha256sum"
      export REAL_SHA256SUM=${pkgs.coreutils}/bin/sha256sum
      export FAKE_SYSTEM=${system}
      export EXPECTED_NIX_SHA=${expectedHash}
      export BOOTSTRAP_ACCOUNT_SHELL_FILE="$TMPDIR/$fixture_name/account-shell"
      export BOOTSTRAP_SHELLS_FILE="$TMPDIR/$fixture_name/shells"
      case "$FAKE_SYSTEM" in
        *-linux) export FAKE_EXPECTED_LOGIN_SHELL="$HOME/.nix-profile/bin/zsh" ;;
        *-darwin) export FAKE_EXPECTED_LOGIN_SHELL=/run/current-system/sw/bin/zsh ;;
        *) exit 64 ;;
      esac
      unset \
        FAKE_ACTIVATION_FAIL \
        FAKE_BAD_SHA \
        FAKE_CHSH_FAIL \
        FAKE_CURL_FAIL \
        FAKE_GIT_FETCH_FAIL \
        FAKE_GIT_UPDATE_REPO \
        FAKE_INSTALLER_FAIL_AFTER_START \
        FAKE_SUDO_FAIL \
        FAKE_VERIFY_FAIL
      mkdir -p "$HOME" "$repo/scripts"
      printf '%s\n' "$FAKE_EXPECTED_LOGIN_SHELL" > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      printf '%s\n' "$FAKE_EXPECTED_LOGIN_SHELL" > "$BOOTSTRAP_SHELLS_FILE"
      cp "$bootstrap" "$repo/install.sh"
      cp "$migration" "$repo/scripts/bootstrap-migrate.sh"
      substituteInPlace "$repo/install.sh" \
        --replace-fail 'readonly BOOTSTRAP_TEST_HOOKS=0' \
        'readonly BOOTSTRAP_TEST_HOOKS=1'
      chmod +x "$repo/install.sh" "$repo/scripts/bootstrap-migrate.sh"
      patchShebangs "$repo/install.sh" "$repo/scripts/bootstrap-migrate.sh"
      printf '{ outputs = _: {}; }\n' > "$repo/flake.nix"
      "$real_git" -C "$repo" init -q -b main
      "$real_git" -C "$repo" config user.name fixture
      "$real_git" -C "$repo" config user.email fixture@example.invalid
      "$real_git" -C "$repo" remote add origin https://github.com/atyrode/dotfiles.git
      "$real_git" -C "$repo" add flake.nix install.sh scripts/bootstrap-migrate.sh
      "$real_git" -C "$repo" commit -q -m fixture
      "$real_git" -C "$repo" update-ref refs/remotes/origin/main HEAD
    }

    expect_failure() {
      if "$@" > "$TMPDIR/unexpected-success.out" 2> "$TMPDIR/expected-failure.err"; then
        echo "command unexpectedly succeeded: $*" >&2
        exit 1
      fi
    }

    make_unmanaged_entrypoints() {
      printf 'zshrc fixture\n' > "$TMPDIR/$fixture_name-zshrc"
      printf 'zshenv fixture\n' > "$TMPDIR/$fixture_name-zshenv"
      ln -s "$TMPDIR/$fixture_name-zshrc" "$HOME/.zshrc"
      ln -s "$TMPDIR/$fixture_name-zshenv" "$HOME/.zshenv"
    }

    # A clean plan is read-only and never invokes Nix, downloads, or creates receipts.
    new_fixture plan
    export PATH="$managed_tools:$base_path"
    "$repo/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/plan.out"
    grep -q '^Preflight passed' "$TMPDIR/plan.out"
    grep -q '^Plan' "$TMPDIR/plan.out"
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
    grep -F '"$BOOTSTRAP_TEST_HOOKS" == 1 && -n "''${BOOTSTRAP_SHELLS_FILE:-}"' \
      "$bootstrap" >/dev/null
    grep -F '"$BOOTSTRAP_TEST_HOOKS" == 1 && -n "''${BOOTSTRAP_ACCOUNT_SHELL_FILE:-}"' \
      "$bootstrap" >/dev/null

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

    # A failed source update is journaled and never reaches activation.
    new_fixture network-failure
    export PATH="$managed_tools:$base_path"
    export FAKE_GIT_FETCH_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --update --repo "$repo" --config "$host"
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test ! -e "$FAKE_LOG"
    test ! -e "$XDG_STATE_HOME"

    # A successful update re-enters the fetched bootstrap and receipts the new revision.
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
    grep -R -F $'revision\t'"$updated_revision" \
      "$XDG_STATE_HOME/atyrode/bootstrap/transactions" >/dev/null

    # Download and integrity failures cannot execute the unverified installer.
    new_fixture download-failure
    export PATH="$fresh_tools:$base_path"
    export FAKE_CURL_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test ! -e "$FAKE_INSTALL_EXECUTED"
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"

    new_fixture checksum-failure
    export PATH="$fresh_tools:$base_path"
    export FAKE_BAD_SHA=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test ! -e "$FAKE_INSTALL_EXECUTED"
    test ! -e "$HOME/.nix-profile/bin/nix"

    new_fixture partial-installer-failure
    export PATH="$fresh_tools:$base_path"
    export FAKE_INSTALLER_FAIL_AFTER_START=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test -e "$FAKE_INSTALL_EXECUTED"
    test ! -e "$HOME/.nix-profile/bin/nix"
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    find "$XDG_STATE_HOME/atyrode/bootstrap/transactions" -name '*.failed' | grep -q .

    # Fresh installation verifies the artifact, migrates shell links, activates,
    # verifies, and remains idempotent on a repeated upgrade-style invocation.
    new_fixture fresh-success
    export PATH="$fresh_tools:$base_path"
    make_unmanaged_entrypoints
    if [[ "$FAKE_SYSTEM" == *-linux ]]; then
      printf '/bin/bash\n' > "$BOOTSTRAP_ACCOUNT_SHELL_FILE"
      : > "$BOOTSTRAP_SHELLS_FILE"
      export SHELL="$FAKE_EXPECTED_LOGIN_SHELL"
    fi
    old_zshrc="$(readlink "$HOME/.zshrc")"
    old_zshenv="$(readlink "$HOME/.zshenv")"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" > "$TMPDIR/fresh.out"
    test -e "$FAKE_INSTALL_EXECUTED"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
    test "$(readlink "$HOME/.zshrc")" = /nix/store/fixture-home-manager-files/.zshrc
    test "$(readlink "$HOME/.zshenv")" = /nix/store/fixture-home-manager-files/.zshenv
    complete_migration="$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.complete"
    test -d "$complete_migration"
    test "$(readlink "$complete_migration/backup/zshrc")" = "$old_zshrc"
    test "$(readlink "$complete_migration/backup/zshenv")" = "$old_zshenv"
    "$repo/install.sh" verify --repo "$repo" --config "$host" >/dev/null
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(readlink "$complete_migration/backup/zshrc")" = "$old_zshrc"
    find "$XDG_STATE_HOME/atyrode/bootstrap/transactions" -name '*.complete' | grep -q .
    test "$(cat "$BOOTSTRAP_ACCOUNT_SHELL_FILE")" = "$FAKE_EXPECTED_LOGIN_SHELL"
    test "$(grep -Fxc -- "$FAKE_EXPECTED_LOGIN_SHELL" "$BOOTSTRAP_SHELLS_FILE")" = 1
    unset SHELL
    if find "$XDG_STATE_HOME/atyrode/bootstrap" -name receipt.tsv \
      -exec grep -F "$HOME" {} + | grep -q .; then
      echo 'receipt exposed an absolute home path' >&2
      exit 1
    fi
    if find "$XDG_STATE_HOME/atyrode/bootstrap" -name receipt.tsv \
      -exec grep -Ei 'token|password|credential|github\.com' {} + | grep -q .; then
      echo 'receipt exposed credential-shaped or remote data' >&2
      exit 1
    fi

    # The conservative prerequisite marker is published before the completed
    # activation receipt. An interruption after that receipt therefore cannot
    # make an unverified login-shell transition look ready.
    new_fixture login-shell-receipt-interruption
    export PATH="$managed_tools:$base_path"
    if BOOTSTRAP_FAILPOINT=after-login-shell-receipt \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'login-shell receipt failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test -f "$XDG_STATE_HOME/atyrode/bootstrap/login-shell.incomplete"
    find "$XDG_STATE_HOME/atyrode/bootstrap/transactions" -name '*.complete' | grep -q .
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
      find "$XDG_STATE_HOME/atyrode/bootstrap/transactions" -name '*.complete' | grep -q .
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

    # Failed activation restores exact pre-activation links and prior host state.
    new_fixture activation-failure
    export PATH="$managed_tools:$base_path"
    make_unmanaged_entrypoints
    mkdir -p "$XDG_STATE_HOME/atyrode"
    printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    old_zshrc="$(readlink "$HOME/.zshrc")"
    old_zshenv="$(readlink "$HOME/.zshenv")"
    export FAKE_ACTIVATION_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test "$(readlink "$HOME/.zshrc")" = "$old_zshrc"
    test "$(readlink "$HOME/.zshenv")" = "$old_zshenv"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.pending"

    # A post-activation verification failure also restores migration-owned paths
    # and the previous active-host receipt instead of being mistaken for success.
    new_fixture verification-failure
    export PATH="$managed_tools:$base_path"
    make_unmanaged_entrypoints
    mkdir -p "$XDG_STATE_HOME/atyrode"
    printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    old_zshrc="$(readlink "$HOME/.zshrc")"
    old_zshenv="$(readlink "$HOME/.zshenv")"
    export FAKE_VERIFY_FAIL=1
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test "$(readlink "$HOME/.zshrc")" = "$old_zshrc"
    test "$(readlink "$HOME/.zshenv")" = "$old_zshenv"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"

    # The pending marker is published atomically only after its recovery payload,
    # receipt, and prior-state snapshot are complete.
    new_fixture transaction-publish-interruption
    export PATH="$managed_tools:$base_path"
    if BOOTSTRAP_FAILPOINT=before-transaction-publish \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'transaction publication failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test -z "$(find "$XDG_STATE_HOME/atyrode/bootstrap/transactions" -mindepth 1 -print -quit)"
    "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    find "$XDG_STATE_HOME/atyrode/bootstrap/transactions" -name '*.abandoned' | grep -q .

    # State and transaction namespaces may not redirect writes through symlinks.
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

    new_fixture transactions-link
    export PATH="$managed_tools:$base_path"
    mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap"
    ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap/transactions"
    expect_failure "$repo/install.sh" apply --yes --repo "$repo" --config "$host"
    test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

    new_fixture pending-link
    export PATH="$managed_tools:$base_path"
    mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap"
    ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    expect_failure "$repo/install.sh" rollback --yes --repo "$repo"

    # An abrupt interruption is recoverable through the explicit rollback phase.
    new_fixture interrupted
    export PATH="$managed_tools:$base_path"
    make_unmanaged_entrypoints
    old_zshrc="$(readlink "$HOME/.zshrc")"
    old_zshenv="$(readlink "$HOME/.zshenv")"
    if BOOTSTRAP_FAILPOINT=after-migration-prepare \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'interruption failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    test -d "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test ! -e "$HOME/.zshrc"
    test ! -e "$HOME/.zshenv"
    "$repo/install.sh" rollback --yes --repo "$repo" >/dev/null
    test "$(readlink "$HOME/.zshrc")" = "$old_zshrc"
    test "$(readlink "$HOME/.zshenv")" = "$old_zshenv"
    test ! -e "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    "$repo/install.sh" rollback --yes --repo "$repo" >/dev/null

    # Recovery uses the transaction-owned, checksummed script and refuses a
    # corrupt migration receipt without archiving the pending transaction.
    new_fixture corrupt-recovery
    export PATH="$managed_tools:$base_path"
    make_unmanaged_entrypoints
    if BOOTSTRAP_FAILPOINT=after-migration-prepare \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'corrupt-recovery setup unexpectedly succeeded' >&2
      exit 1
    fi
    printf 'move\t../escape\tsymlink\n' >> \
      "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.pending/receipt.tsv"
    expect_failure "$repo/install.sh" rollback --yes --repo "$repo"
    test -d "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test -d "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.pending"

    new_fixture tampered-recovery
    export PATH="$managed_tools:$base_path"
    make_unmanaged_entrypoints
    if BOOTSTRAP_FAILPOINT=after-migration-prepare \
      "$repo/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
      echo 'tampered-recovery setup unexpectedly succeeded' >&2
      exit 1
    fi
    printf '\n# tampered\n' >> \
      "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending/recovery/bootstrap-migrate.sh"
    expect_failure "$repo/install.sh" rollback --yes --repo "$repo"
    test -d "$XDG_STATE_HOME/atyrode/bootstrap/apply.pending"
    test -d "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.pending"

    # Production migration ignores ambient failpoints; only the build-time
    # test copy can simulate interruption.
    export HOME="$TMPDIR/production-migration/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    fixture_name=production-migration
    make_unmanaged_entrypoints
    old_zshrc="$(readlink "$HOME/.zshrc")"
    old_zshenv="$(readlink "$HOME/.zshenv")"
    BOOTSTRAP_MIGRATION_FAILPOINT=after-zshrc \
      bash "$production_migration" prepare >/dev/null
    test ! -e "$HOME/.zshrc"
    test ! -e "$HOME/.zshenv"
    bash "$production_migration" rollback >/dev/null
    test "$(readlink "$HOME/.zshrc")" = "$old_zshrc"
    test "$(readlink "$HOME/.zshenv")" = "$old_zshenv"

    # Migration preparation resumes after an interruption. Rollback validates all
    # destinations first, so a collision cannot cause a partial restore.
    export HOME="$TMPDIR/migration/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    fixture_name=migration
    make_unmanaged_entrypoints
    old_zshrc="$(readlink "$HOME/.zshrc")"
    old_zshenv="$(readlink "$HOME/.zshenv")"
    if BOOTSTRAP_MIGRATION_FAILPOINT=after-zshrc bash "$migration" prepare >/dev/null 2>&1; then
      echo 'migration interruption failpoint unexpectedly succeeded' >&2
      exit 1
    fi
    test ! -e "$HOME/.zshrc"
    test -L "$HOME/.zshenv"
    bash "$migration" prepare >/dev/null
    ln -s /nix/store/fixture-home-manager-files/.zshrc "$HOME/.zshrc"
    ln -s /nix/store/fixture-home-manager-files/.zshenv "$HOME/.zshenv"
    bash "$migration" commit >/dev/null
    rm "$HOME/.zshrc"
    printf 'replacement\n' > "$HOME/.zshrc"
    expect_failure bash "$migration" rollback
    test -L "$HOME/.zshenv"
    test -L "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.complete/backup/zshenv"
    rm "$HOME/.zshrc"
    bash "$migration" rollback >/dev/null
    test "$(readlink "$HOME/.zshrc")" = "$old_zshrc"
    test "$(readlink "$HOME/.zshenv")" = "$old_zshenv"

    export HOME="$TMPDIR/dual-migration/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    printf 'dual\n' > "$TMPDIR/dual-target"
    ln -s "$TMPDIR/dual-target" "$HOME/.zshrc"
    bash "$migration" prepare >/dev/null
    ln -s /nix/store/fixture-home-manager-files/.zshrc "$HOME/.zshrc"
    bash "$migration" commit >/dev/null
    migration_root="$XDG_STATE_HOME/atyrode/bootstrap/migrations"
    cp -R "$migration_root/migration-v1-shell-entrypoints.complete" \
      "$migration_root/migration-v1-shell-entrypoints.pending"
    expect_failure bash "$migration" status

    export HOME="$TMPDIR/missing-backup/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    printf 'missing\n' > "$TMPDIR/missing-target"
    ln -s "$TMPDIR/missing-target" "$HOME/.zshrc"
    bash "$migration" prepare >/dev/null
    ln -s /nix/store/fixture-home-manager-files/.zshrc "$HOME/.zshrc"
    bash "$migration" commit >/dev/null
    rm "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.complete/backup/zshrc"
    expect_failure bash "$migration" status

    export HOME="$TMPDIR/missing-pending-backup/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    printf 'pending missing\n' > "$TMPDIR/pending-missing-target"
    ln -s "$TMPDIR/pending-missing-target" "$HOME/.zshrc"
    bash "$migration" prepare >/dev/null
    ln -s /nix/store/fixture-home-manager-files/.zshrc "$HOME/.zshrc"
    pending_migration="$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.pending"
    rm "$pending_migration/backup/zshrc"
    expect_failure bash "$migration" rollback
    test -d "$pending_migration"
    test "$(readlink "$HOME/.zshrc")" = /nix/store/fixture-home-manager-files/.zshrc

    export HOME="$TMPDIR/terminal-link/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    terminal_root="$XDG_STATE_HOME/atyrode/bootstrap/migrations"
    mkdir -p "$terminal_root"
    ln -s "$HOME/missing" "$terminal_root/migration-v1-shell-entrypoints.pending"
    expect_failure bash "$migration" status

    export HOME="$TMPDIR/terminal-file/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    terminal_root="$XDG_STATE_HOME/atyrode/bootstrap/migrations"
    mkdir -p "$terminal_root"
    printf 'invalid\n' > "$terminal_root/migration-v1-shell-entrypoints.complete"
    expect_failure bash "$migration" rollback

    export HOME="$TMPDIR/regular-entrypoint/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    printf 'regular shell entrypoint\n' > "$HOME/.zshrc"
    bash "$migration" prepare >/dev/null
    test ! -e "$HOME/.zshrc"
    test "$(cat "$XDG_STATE_HOME/atyrode/bootstrap/migrations/migration-v1-shell-entrypoints.pending/backup/zshrc")" = \
      'regular shell entrypoint'
    ln -s /nix/store/fixture-home-manager-files/.zshrc "$HOME/.zshrc"
    bash "$migration" commit >/dev/null
    bash "$migration" rollback >/dev/null
    test -f "$HOME/.zshrc"
    test "$(cat "$HOME/.zshrc")" = 'regular shell entrypoint'

    mkdir "$out"
  ''
