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
  # The fixtures and fake tools are a file the scenario groups source rather
  # than a preamble each of them inlines, because a group is only worth
  # splitting out if it can rebuild alone: an inlined string would put every
  # scenario back into one derivation's inputs. Interpolations still resolve,
  # since writeText expands them as it writes the file.
  harness = pkgs.writeText "bootstrap-harness.sh" ''
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

    bootstrap=${../../../bootstrap/install.sh}
    system_policy=${../../../fleet/system-boundary.json}
    real_git=${pkgs.git}/bin/git
    base_path="$PATH"
    host="alex-${system}"
    tool_root="$TMPDIR/tools"
    fresh_tools="$tool_root/fresh"
    managed_tools="$tool_root/managed"
    fake_nix_template="$tool_root/fake-nix"
    fake_installer_template="$tool_root/fake-installer"


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
          *" --preview-json "*)
            if [ "''${FAKE_BUILD_FAIL:-0}" = 1 ]; then
              printf "error: Cannot build '/nix/store/00000000000000000000000000000000-darwin-system-26.11.drv'.\n       Reason: builder failed with exit code 1.\n" >&2
              exit 1
            fi
            printf '{"disruption":{"schemaVersion":1,"status":"%s","fingerprint":"%s","effects":[]}}\n' \
              "''${FAKE_DISRUPTION_STATUS:-safe}" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            exit 0
            ;;
        esac
        case " $* " in
          *" --expected-disruption aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "*) ;;
          *) exit 65 ;;
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
      mkdir -p "$HOME" "$repo/bootstrap"
      cp "$bootstrap" "$repo/bootstrap/install.sh"
      substituteInPlace "$repo/bootstrap/install.sh" \
        --replace-fail 'readonly BOOTSTRAP_TEST_HOOKS=0' \
        'readonly BOOTSTRAP_TEST_HOOKS=1'
      chmod +x "$repo/bootstrap/install.sh"
      patchShebangs "$repo/bootstrap/install.sh"
      printf '{ outputs = _: {}; }\n' > "$repo/flake.nix"
      # Bootstrap reads the fleet cache from the inventory, so the fixture
      # checkout carries the real file rather than a stand-in.
      mkdir -p "$repo/fleet"
      cp "$system_policy" "$repo/fleet/system-boundary.json"
      "$real_git" -C "$repo" init -q -b main
      "$real_git" -C "$repo" config user.name fixture
      "$real_git" -C "$repo" config user.email fixture@example.invalid
      "$real_git" -C "$repo" remote add origin https://github.com/atyrode/dotfiles.git
      "$real_git" -C "$repo" add flake.nix bootstrap fleet
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
  '';
in
{
  mkScenario =
    name: body:
    pkgs.runCommand "check-bootstrap-${name}-${system}" { inherit nativeBuildInputs; } ''
      source ${harness}
      ${body}
      mkdir "$out"
    '';
}
