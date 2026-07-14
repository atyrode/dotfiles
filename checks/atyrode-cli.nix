{
  atyrode,
  pkgs,
  productionAtyrode,
  productionHost,
}:

pkgs.runCommand "check-atyrode-cli"
  {
    nativeBuildInputs = [
      atyrode
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
      *ls-remote*) printf 'feedfacefeedfacefeedfacefeedfacefeedface\trefs/heads/main\n' ;;
      *) exit 1 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/nh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" > "$TMPDIR/nh-args"
    if [[ "''${ATYRODE_NH_NOISE:-0}" == 1 ]]; then
      # Reproduce nh clean's real output shape: a genuine generation removal, the
      # benign root-owned gcroots permission flood, and one real (non-permission)
      # error — so the check can prove fold_gcroots_noise keeps the first and last
      # while collapsing the flood.
      echo '- OK  /home/alex/.local/state/nix/profiles/profile-9-link'
      echo '> Removing /nix/var/nix/gcroots/auto/lvi04m7mn76ymzgzcx5rrifj5019psvd'
      echo '! Failed to remove path="/nix/var/nix/gcroots/auto/lvi04m7mn76ymzgzcx5rrifj5019psvd" err=Os { code: 13, kind: PermissionDenied, message: "Permission denied" } (nh/crates/nh-clean/src/clean.rs:606)'
      echo '> Removing /nix/var/nix/gcroots/auto/phm61mw9l2zpvj3fj6pmmyk22b1l3qg8'
      echo '! Failed to remove path="/nix/var/nix/gcroots/auto/phm61mw9l2zpvj3fj6pmmyk22b1l3qg8" err=Os { code: 13, kind: PermissionDenied, message: "Permission denied" } (nh/crates/nh-clean/src/clean.rs:606)'
      echo '! Failed to remove path="/nix/store/genuine" err=Os { code: 2, kind: NotFound }' >&2
    fi
    [[ "''${ATYRODE_NH_FAIL:-0}" != 1 ]]
    EOF
    # Stub nix-env's generation listing (clean --json / generations read it).
    cat > "$TMPDIR/bin/nix-env" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      *--list-generations*)
        echo "  1   2026-05-01 10:00:00"
        echo "  2   2026-06-01 10:00:00"
        echo "  3   2026-07-01 10:00:00   (current)" ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/git" "$TMPDIR/bin/nh" "$TMPDIR/bin/nix-env"
    # Make the home-manager generations profile path exist so clean/generations
    # accept it (gen_profile → $XDG_STATE_HOME/nix/profiles/home-manager).
    mkdir -p "$XDG_STATE_HOME/nix/profiles"
    touch "$XDG_STATE_HOME/nix/profiles/home-manager"
    export PATH="$TMPDIR/bin:$PATH"
    export ATYRODE_GIT="$TMPDIR/bin/git"
    export ATYRODE_NH="$TMPDIR/bin/nh"
    export ATYRODE_NIX_ENV="$TMPDIR/bin/nix-env"
    # Pin the generations profile so clean --json is platform-agnostic in the
    # check (on darwin gen_profile would otherwise point at the system profile).
    export ATYRODE_GEN_PROFILE="$XDG_STATE_HOME/nix/profiles/home-manager"
    export _ATYRODE_TEST_HOSTNAME="fixture-linux"
    export _ATYRODE_TEST_SYSTEM="x86_64-linux"
    export _ATYRODE_TEST_USER="alex"

    # Production packages ignore every test-only identity override. Otherwise
    # a project environment could spoof apply and doctor preflight identity.
    set +e
    env \
      _ATYRODE_TEST_HOSTNAME=spoofed \
      _ATYRODE_TEST_SYSTEM=${pkgs.stdenv.hostPlatform.system} \
      _ATYRODE_TEST_USER=alex \
      ${productionAtyrode}/bin/atyrode doctor host ${productionHost} --json \
      > "$TMPDIR/production-identity.out" 2> "$TMPDIR/production-identity.err"
    production_identity_status="$?"
    set -e
    test "$production_identity_status" = 65

    atyrode capabilities list --json | jq -e '
      (map(.name) | index("base") and index("server"))
      and all(.[]; .description | length > 0)
      and (.[] | select(.name == "base") | .active)
      and ((.[] | select(.name == "desktop") | .active) | not)
    ' >/dev/null
    atyrode capabilities show alex-linux --json | jq -e '
      .host == "alex-x86_64-linux"
      and (.description | length > 0)
      and (.capabilities | map(.name) | index("agent-tools"))
      and all(.capabilities[]; .description | length > 0)
    ' >/dev/null

    # On a machine whose identity is ambiguous the list degrades to
    # unmarked instead of dying.
    mv "$XDG_CONFIG_HOME/atyrode/host.json" "$TMPDIR/host.json"
    atyrode capabilities list --json | jq -e 'all(.[]; .active | not)' >/dev/null
    mv "$TMPDIR/host.json" "$XDG_CONFIG_HOME/atyrode/host.json"
    atyrode doctor host --json | jq -e '.ok and .registered.id == "alex-x86_64-linux"' >/dev/null
    tools="$(atyrode doctor tools --json || true)"
    jq -e '
      any(.[]; .name == "OMP"
        and .capability == "agent-tools"
        and (.launchModes | index("untrusted"))
        and (.versionOwner | length > 0))
      and all(.[]; .status != "missing" or (.remediation | contains("do not install globally")))
    ' <<< "$tools" >/dev/null
    atyrode apply --repo "$HOME/nix-dotfiles" --plan --json | jq -e '
      .host == "alex-x86_64-linux"
      and .backend == "nh-home"
      and .source == "local"
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
    grep -F -- "home switch $HOME/nix-dotfiles --configuration alex-x86_64-linux" \
      "$TMPDIR/nh-args" >/dev/null
    grep -F -- '--dry' "$TMPDIR/nh-args" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

    atyrode apply --plan --json | jq -e '
      .source == "remote"
      and .revision == "feedfacefeed"
      and .installable == "github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface#alex-x86_64-linux"
      and (.dirty | not)
      and .repository == "github:atyrode/dotfiles"
    ' >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

    atyrode apply >/dev/null
    # nh home must receive the bare flake reference; a #fragment form is
    # passed to nix verbatim and fails attribute resolution.
    grep -F -- 'home switch github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface --configuration alex-x86_64-linux' \
      "$TMPDIR/nh-args" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = alex-x86_64-linux

    atyrode apply --ref 0123456789012345678901234567890123456789 --plan --json | jq -e '
      .source == "remote" and .revision == "012345678901"
    ' >/dev/null

    if atyrode apply --ref main --repo "$HOME/nix-dotfiles" --plan >/dev/null 2>&1; then
      echo '--ref with --repo unexpectedly succeeded' >&2
      exit 1
    fi

    if atyrode apply alex-aarch64-linux --plan >/dev/null 2>&1; then
      echo 'cross-system host selection unexpectedly succeeded' >&2
      exit 1
    fi

    # System diagnostics distinguish installed binaries from operational
    # readiness without touching the build host's account or services.
    linux_ready="$TMPDIR/linux-ready.json"
    jq -n --arg path "$HOME/.nix-profile/bin/zsh" '{
      loginShell: {path:$path, executable:true, listed:true},
      nix: {
        daemonReachable:true,
        trustedUsersExact:true,
        officialCacheOnly:true,
        officialKeyOnly:true,
        signaturesRequired:true,
        optimiserScheduled:false,
        rawSubstituter:"https://super-secret@example.invalid/cache?token=super-secret"
      },
      container: {dockerGroup:false, mode:"rootless"},
      device: {adbAvailable:true, policy:"uaccess"},
      homebrew: {available:false, drift:false}
    }' > "$linux_ready"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$linux_ready"
    system_result="$(atyrode doctor system alex-x86_64-linux-desktop --json)"
    jq -e '
      .schemaVersion == 1
      and .command == "doctor system"
      and .ok
      and .mutationBoundary == "read-only probes"
      and (.checks | map(.id)) == [
        "login-shell",
        "nix-daemon",
        "nix-policy",
        "container-engine",
        "antivirus-data",
        "device-permissions",
        "homebrew-drift"
      ]
      and (.checks[] | select(.id == "container-engine") | .actual.mode) == "rootless"
      and (.checks[] | select(.id == "antivirus-data") | .code) == "not-configured"
      and (.checks[] | select(.id == "homebrew-drift") | .status) == "not-applicable"
    ' <<< "$system_result" >/dev/null
    if grep -q 'super-secret' <<< "$system_result"; then
      echo 'system diagnostics exposed raw Nix configuration' >&2
      exit 1
    fi

    minimal_result="$(atyrode doctor system alex-x86_64-linux --json)"
    # alex-x86_64-linux carries the containers capability but not mobile, so
    # container-engine resolves against the rootless fixture (ok) while
    # device-permissions stays not-applicable — a mixed host, unlike the desktop.
    jq -e '
      .ok
      and (.checks[] | select(.id == "container-engine") | .status) == "ok"
      and (.checks[] | select(.id == "device-permissions") | .status) == "not-applicable"
    ' <<< "$minimal_result" >/dev/null

    antivirus_present="$TMPDIR/antivirus-present.json"
    jq '.antivirus.binariesPresent = true' "$linux_ready" > "$antivirus_present"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$antivirus_present"
    if atyrode doctor system alex-x86_64-linux-desktop --json > "$TMPDIR/antivirus-present.out"; then
      echo 'unmanaged ClamAV binaries unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.checks[] | select(.id == "antivirus-data") | .code) == "unmanaged-antivirus-present"
    ' "$TMPDIR/antivirus-present.out" >/dev/null

    # The real Android rule parser requires one active Android/ADB-identified
    # vendor line to carry the accepted access policy. It ignores unrelated,
    # split, commented, and unreadable rules without printing filesystem errors.
    android_probe="$TMPDIR/android-probe.json"
    jq '.device = {adbAvailable:true}' "$linux_ready" > "$android_probe"
    android_rules="$TMPDIR/udev-rules"
    mkdir "$android_rules"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$android_probe"
    export _ATYRODE_TEST_UDEV_ROOT="$android_rules"
    cat > "$android_rules/51-android.rules" <<'EOF'
    SUBSYSTEM=="usb", ATTR{idVendor}=="18d1"
    SUBSYSTEM=="video4linux", TAG+="uaccess"
    EOF
    if atyrode doctor system alex-x86_64-linux-desktop --json \
      > "$TMPDIR/android-split.out" 2> "$TMPDIR/android-split.err"; then
      echo 'unrelated Android rule lines unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    test ! -s "$TMPDIR/android-split.err"
    jq -e '
      (.checks[] | select(.id == "device-permissions") | .code) == "android-device-permissions"
    ' "$TMPDIR/android-split.out" >/dev/null

    cat > "$android_rules/51-android.rules" <<'EOF'
    SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", TAG+="uaccess"
    EOF
    atyrode doctor system alex-x86_64-linux-desktop --json | jq -e '.ok' >/dev/null

    chmod 000 "$android_rules/51-android.rules"
    if atyrode doctor system alex-x86_64-linux-desktop --json \
      > "$TMPDIR/android-unreadable.out" 2> "$TMPDIR/android-unreadable.err"; then
      echo 'an unreadable Android rule unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    test ! -s "$TMPDIR/android-unreadable.err"
    chmod 600 "$android_rules/51-android.rules"
    unset _ATYRODE_TEST_UDEV_ROOT

    linux_incomplete="$TMPDIR/linux-incomplete.json"
    jq -n '{
      loginShell: {path:"/bin/bash", executable:true, listed:true},
      nix: {
        daemonReachable:false,
        trustedUsersExact:false,
        officialCacheOnly:false,
        officialKeyOnly:false,
        signaturesRequired:false,
        optimiserScheduled:false
      },
      container: {dockerGroup:true, mode:"rootful"},
      device: {adbAvailable:true, policy:"missing"},
      homebrew: {available:false, drift:true}
    }' > "$linux_incomplete"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$linux_incomplete"
    if atyrode doctor system alex-x86_64-linux-desktop --json > "$TMPDIR/linux-incomplete.out"; then
      echo 'incomplete Linux system unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.ok | not)
      and ([.checks[] | select(.status == "incomplete") | .code] | index("login-shell-mismatch"))
      and ([.checks[] | select(.status == "incomplete") | .code] | index("nix-daemon-unreachable"))
      and ([.checks[] | select(.status == "incomplete") | .code] | index("nix-policy-drift"))
      and ([.checks[] | select(.status == "incomplete") | .code] | index("docker-group-membership"))
      and ([.checks[] | select(.status == "incomplete") | .code] | index("android-device-permissions"))
    ' "$TMPDIR/linux-incomplete.out" >/dev/null

    server_ready="$TMPDIR/server-ready.json"
    jq '.loginShell.path = "/run/current-system/sw/bin/zsh"' "$linux_ready" > "$server_ready"
    export _ATYRODE_TEST_USER=fixture
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$server_ready"
    server_result="$(atyrode doctor system fixture-server --json)"
    jq -e '
      .ok
      and ([.checks[] | select(.id == "login-shell" or .id == "nix-daemon" or
          .id == "nix-policy" or .id == "container-engine" or
          .id == "antivirus-data" or .id == "device-permissions") | .owner]
        | all(. == "nixos"))
    ' <<< "$server_result" >/dev/null

    darwin_ready="$TMPDIR/darwin-ready.json"
    jq -n '{
      loginShell: {path:"/run/current-system/sw/bin/zsh", executable:true, listed:true},
      nix: {
        daemonReachable:true,
        trustedUsersExact:true,
        officialCacheOnly:true,
        officialKeyOnly:true,
        signaturesRequired:true,
        optimiserScheduled:true
      },
      container: {dockerGroup:false, mode:"orbstack"},
      device: {adbAvailable:true, policy:"macos-user-authorization"},
      homebrew: {available:true, drift:false}
    }' > "$darwin_ready"
    export _ATYRODE_TEST_SYSTEM="aarch64-darwin"
    export _ATYRODE_TEST_USER=alex
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$darwin_ready"
    darwin_result="$(atyrode doctor system alex-aarch64-darwin --json)"
    jq -e '
      .ok
      and .platform == "darwin"
      and (.checks[] | select(.id == "container-engine") | .actual.mode) == "orbstack"
      and (.checks[] | select(.id == "device-permissions") | .status) == "ok"
      and (.checks[] | select(.id == "homebrew-drift") | .status) == "ok"
    ' <<< "$darwin_result" >/dev/null

    darwin_missing_adb="$TMPDIR/darwin-missing-adb.json"
    jq '.device.adbAvailable = false' "$darwin_ready" > "$darwin_missing_adb"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$darwin_missing_adb"
    if atyrode doctor system alex-aarch64-darwin --json > "$TMPDIR/darwin-missing-adb.out"; then
      echo 'Darwin mobile readiness ignored a missing ADB binary' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.checks[] | select(.id == "device-permissions") | .code) == "android-tools-missing"
    ' "$TMPDIR/darwin-missing-adb.out" >/dev/null

    darwin_drift="$TMPDIR/darwin-drift.json"
    jq '.homebrew.drift = true' "$darwin_ready" > "$darwin_drift"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$darwin_drift"
    if atyrode doctor system alex-aarch64-darwin --json > "$TMPDIR/darwin-drift.out"; then
      echo 'Homebrew drift unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.checks[] | select(.id == "homebrew-drift") | .code) == "homebrew-drift"
    ' "$TMPDIR/darwin-drift.out" >/dev/null

    darwin_probe_failure="$TMPDIR/darwin-probe-failure.json"
    jq '.homebrew.probeFailed = true' "$darwin_ready" > "$darwin_probe_failure"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$darwin_probe_failure"
    if atyrode doctor system alex-aarch64-darwin --json > "$TMPDIR/darwin-probe-failure.out"; then
      echo 'Homebrew probe failure unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.checks[] | select(.id == "homebrew-drift") | .code) == "homebrew-probe-failed"
    ' "$TMPDIR/darwin-probe-failure.out" >/dev/null

    export _ATYRODE_TEST_SYSTEM="x86_64-linux"
    export _ATYRODE_TEST_USER="fixture"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$linux_ready"
    security_result="$(atyrode doctor system fixture-security --json)"
    jq -e '
      (.checks[] | select(.id == "antivirus-data") | .status) == "not-applicable"
      and (.checks[] | select(.id == "antivirus-data") | .code) == "not-configured"
    ' <<< "$security_result" >/dev/null

    if atyrode doctor system fixture-security --unknown >/dev/null 2>&1; then
      echo 'unknown doctor system option unexpectedly succeeded' >&2
      exit 1
    else
      test "$?" -eq 64
    fi
    export _ATYRODE_TEST_USER="wrong-user"
    if atyrode doctor system fixture-security --json >/dev/null 2>&1; then
      echo 'system diagnostics ignored host identity mismatch' >&2
      exit 1
    else
      test "$?" -eq 65
    fi

    if grep -Eq 'brew bundle cleanup .*--(force|zap)|(^|[[:space:]])(sudo|chsh|usermod|freshclam)([[:space:]]|$)|adb[[:space:]]+devices' \
      ${../pkgs/atyrode/atyrode}; then
      echo 'doctor system contains a mutating system probe' >&2
      exit 1
    fi
    grep -F 'brew bundle check --no-upgrade --file "$homebrew_brewfile" </dev/null' \
      ${../pkgs/atyrode/atyrode} >/dev/null
    grep -F 'brew bundle cleanup --file "$homebrew_brewfile" </dev/null' \
      ${../pkgs/atyrode/atyrode} >/dev/null

    # store-lifecycle guards (#21): cleanup keeps a rollback window, rollback
    # refuses the current generation, and the trio is wired (not reserved) — so
    # the current generation and the configured rollback set can't be destroyed.
    grep -F 'keep=5 keep_since=30d' ${../pkgs/atyrode/atyrode} >/dev/null
    grep -F 'is already current' ${../pkgs/atyrode/atyrode} >/dev/null
    for wired in 'clean) cmd_clean' 'rollback) cmd_rollback' 'generations) cmd_generations'; do
      grep -F "$wired" ${../pkgs/atyrode/atyrode} >/dev/null || { echo "atyrode: $wired not wired" >&2; exit 1; }
    done
    # cleanup must never be an implicit side effect of apply
    if awk '/^apply_config\(\) \{/{f=1} f&&/cmd_clean|cmd_rollback/{print; hit=1} /^\}/{if(f)f=0} END{exit hit?0:1}' \
      ${../pkgs/atyrode/atyrode}; then
      echo 'apply invokes cleanup/rollback implicitly' >&2
      exit 1
    fi
    grep -F '"$test_hooks" == 1 && -n "''${ATYRODE_GIT:-}"' \
      ${../pkgs/atyrode/atyrode} >/dev/null
    grep -F '"$test_hooks" == 1 && -n "''${ATYRODE_NH:-}"' \
      ${../pkgs/atyrode/atyrode} >/dev/null

    # clean splits the GC out of nh (--no-gc) and runs it itself so the slow
    # phase can show progress; a stub stands in for the real collector.
    cat > "$TMPDIR/bin/fake-gc" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" > "$TMPDIR/gc-args"
    EOF
    chmod +x "$TMPDIR/bin/fake-gc"
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
    atyrode clean --keep 3 >/dev/null 2>&1
    grep -F -- '--no-gc' "$TMPDIR/nh-args" >/dev/null \
      || { echo 'clean must pass --no-gc to nh' >&2; exit 1; }
    grep -F -- '--gc' "$TMPDIR/gc-args" >/dev/null \
      || { echo 'clean must run the garbage collector' >&2; exit 1; }
    rm -f "$TMPDIR/gc-args"
    atyrode clean -n >/dev/null 2>&1
    test ! -e "$TMPDIR/gc-args" \
      || { echo 'dry-run clean must not collect garbage' >&2; exit 1; }
    unset ATYRODE_NIX_STORE

    # clean --json emits a machine-readable reclaim summary on stdout; nh's own
    # chatter must go to stderr. With 3 generations (current #3) and --keep 2, the
    # only reclaim candidate is generation #1 (beyond the newest 2, not current).
    clean_json="$(atyrode clean --dry-run --json --keep 2 2>/dev/null)"
    jq -e '
      .dryRun == true and .keep == 2 and .scope == "user"
      and .generations.total == 3 and .generations.candidates == 1
      and (.reclaimCandidates | length) == 1
      and .reclaimCandidates[0].generation == 1
    ' <<<"$clean_json" >/dev/null \
      || { echo "clean --json summary wrong: $clean_json" >&2; exit 1; }

    # clean folds nh's benign root-owned gcroots permission flood into a single
    # summary line, but keeps genuine removals and real (non-permission) errors.
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
    noise_out="$(ATYRODE_NH_NOISE=1 atyrode clean --keep 3 2>&1 >/dev/null)"
    unset ATYRODE_NIX_STORE
    grep -qF 'skipped 2 root-owned GC root(s)' <<<"$noise_out" \
      || { echo "clean must summarize skipped gcroots: $noise_out" >&2; exit 1; }
    grep -qF 'gcroots/auto/lvi04m7mn76' <<<"$noise_out" \
      && { echo 'clean must not print individual gcroots permission failures' >&2; exit 1; }
    grep -qF 'profile-9-link' <<<"$noise_out" \
      || { echo 'clean must keep genuine generation removals' >&2; exit 1; }
    grep -qF '/nix/store/genuine' <<<"$noise_out" \
      || { echo 'clean must keep real (non-permission) failures' >&2; exit 1; }

    mkdir "$out"
  ''
