{
  atyrode,
  pkgs,
  productionAtyrode,
  productionHost,
}:

let
  fixtures = import ./lib/atyrode-fixtures.nix { inherit pkgs; };
in
pkgs.runCommand "check-atyrode-apply"
  {
    nativeBuildInputs = [
      atyrode
      pkgs.gh
      pkgs.jq
    ];
  }
  ''
    ${fixtures.base}
    ${fixtures.gitNh}
    ${fixtures.identity}
    cat > "$TMPDIR/bin/fake-systemd-run" <<'EOF'
    #!${pkgs.runtimeShell}
    mkdir -p "$TMPDIR/fake-systemd"
    printf '%s\n' "$*" >> "$TMPDIR/fake-systemd/run-args"
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --unit=*) unit="''${1#--unit=}"; shift ;;
        --setenv=*) export "''${1#--setenv=}"; shift ;;
        --) shift; break ;;
        *) shift ;;
      esac
    done
    [[ -n "$unit" && $# -gt 0 ]] || exit 64
    ${pkgs.util-linux}/bin/setsid "$@" </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$TMPDIR/fake-systemd/$unit.pid"
    EOF
    cat > "$TMPDIR/bin/fake-systemctl" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      *show-environment*) exit 0 ;;
      *is-active*)
        unit=""
        for arg in "$@"; do unit="$arg"; done
        pid_file="$TMPDIR/fake-systemd/$unit.pid"
        [[ -r "$pid_file" ]] || exit 3
        kill -0 "$(cat "$pid_file")" 2>/dev/null
        ;;
      *) exit 64 ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/fake-systemd-run" "$TMPDIR/bin/fake-systemctl"
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

    # A production binary must REFUSE a store-mutating command when a test-only
    # tool-substitution override is set: those seams are ignored in production, so
    # a stubbed-looking clean/apply/rollback would otherwise drive the real
    # nh/nix-store against the live store. (Regression guard for a near-miss where
    # the production binary was run with stub overrides during development.)
    for prod_cmd in clean apply rollback; do
      set +e
      env -u ATYRODE_NH -u ATYRODE_NIX_ENV -u ATYRODE_GIT -u ATYRODE_GEN_PROFILE \
        ATYRODE_NIX_STORE=/bin/true \
        ${productionAtyrode}/bin/atyrode "$prod_cmd" --yes \
        > /dev/null 2> "$TMPDIR/prod-guard.err"
      prod_guard_status="$?"
      set -e
      test "$prod_guard_status" = 64 \
        || { echo "production $prod_cmd must refuse a tool override (exit $prod_guard_status): $(cat "$TMPDIR/prod-guard.err")" >&2; exit 1; }
      grep -qF 'ATYRODE_NIX_STORE is set' "$TMPDIR/prod-guard.err" \
        || { echo "production $prod_cmd refusal must name the offending override" >&2; exit 1; }
    done
    for override in ATYRODE_SYSTEMD_RUN ATYRODE_SYSTEMCTL ATYRODE_FETCH; do
      set +e
      env -u ATYRODE_NH -u ATYRODE_NIX_ENV -u ATYRODE_GIT -u ATYRODE_GEN_PROFILE \
        "$override=/bin/true" ${productionAtyrode}/bin/atyrode apply --plan \
        > /dev/null 2> "$TMPDIR/prod-apply-manager-guard.err"
      prod_apply_manager_guard_status="$?"
      set -e
      test "$prod_apply_manager_guard_status" = 64
      grep -qF "$override is set" "$TMPDIR/prod-apply-manager-guard.err"
    done
    # The guard is scoped to mutating verbs: a read-only command with the same
    # override present still runs (production simply ignores the var there).
    env ATYRODE_NIX_STORE=/bin/true ${productionAtyrode}/bin/atyrode --help >/dev/null 2>&1 \
      || { echo 'production read-only commands must not be blocked by the mutation guard' >&2; exit 1; }

    # Bare invocation is additive: a TTY enters the cockpit and passes the
    # installed Bash CLI through for shell-outs; the same invocation without a
    # TTY remains the scriptable CLI help surface. makeWrapper renames that Bash
    # payload to .atyrode-wrapped and puts the public launcher in front of it.
    cockpit_dispatch="$(_ATYRODE_TEST_TTY=1 atyrode)"
    case "$cockpit_dispatch" in
      cockpit:*/bin/.atyrode-wrapped:0) ;;
      *) echo "bare TTY did not pass the packaged CLI to the cockpit: $cockpit_dispatch" >&2; exit 1 ;;
    esac
    forced_tty_subcommand="$(_ATYRODE_TEST_TTY=1 atyrode capabilities list --json)"
    jq -e 'type == "array" and length > 0' <<<"$forced_tty_subcommand" >/dev/null \
      || { echo "explicit subcommand entered the cockpit under forced TTY: $forced_tty_subcommand" >&2; exit 1; }
    atyrode </dev/null | grep -qF 'Usage:'

    atyrode capabilities list --json | jq -e '
      (map(.name) | index("base") and index("server"))
      and all(.[]; .description | length > 0)
      and (.[] | select(.name == "base") | .active)
      and ((.[] | select(.name == "desktop") | .active) | not)
    ' >/dev/null
    atyrode capabilities show alex-x86_64-linux --json | jq -e '
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
      and .resolvedRevision == "0123456789abcdef0123456789abcdef01234567"
      and .mutationBoundary == "activation only after preflight"
    ' >/dev/null
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"

    LC_CTYPE=UTF-8 atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-success.err" ||
      { cat "$TMPDIR/apply-success.err" >&2; exit 1; }
    # A successful apply with neither Babel's storage document nor a success
    # stamp names the provisioning ceremony, without failing the activation and
    # without prompting (the ceremony needs an unlocked vault).
    grep -qF 'babel archive not configured; configure with: ~/nix-dotfiles/scripts/babel-storage-configure.sh' \
      "$TMPDIR/apply-success.err"
    ! grep -qiF 'set up session backup' "$TMPDIR/apply-success.err"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = alex-x86_64-linux
    test -z "$(find "$XDG_STATE_HOME/atyrode" -name '.dotfiles-config.*' -print -quit)"
    test "$(cat "$TMPDIR/nh-locale")" = C.UTF-8

    # Babel's storage document present but no success stamp: the archive has
    # never run here, so point at Babel's own status and push commands.
    mkdir -p "$XDG_CONFIG_HOME/babel"
    printf '%s\n' '{}' > "$XDG_CONFIG_HOME/babel/storage.json"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-new.err" ||
      { cat "$TMPDIR/apply-archive-new.err" >&2; exit 1; }
    grep -qF 'babel archive has never succeeded here; check with: babel archive status (then: babel archive push)' \
      "$TMPDIR/apply-archive-new.err"

    # A stamp older than the staleness window warns and still activates.
    mkdir -p "$XDG_STATE_HOME/babel"
    date -u -d '3 days ago' +%FT%TZ > "$XDG_STATE_HOME/babel/last-success"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-stale.err" ||
      { cat "$TMPDIR/apply-archive-stale.err" >&2; exit 1; }
    grep -qE 'babel archive stale \(last success: [^)]+\); check with: babel archive status' \
      "$TMPDIR/apply-archive-stale.err"

    # A fresh stamp is silent.
    date -u +%FT%TZ > "$XDG_STATE_HOME/babel/last-success"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-fresh.err" ||
      { cat "$TMPDIR/apply-archive-fresh.err" >&2; exit 1; }
    ! grep -qF 'babel archive' "$TMPDIR/apply-archive-fresh.err"

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

    preview="$(atyrode apply --repo "$HOME/nix-dotfiles" --preview-json)"
    jq -e '
      .schemaVersion == 1
      and .host == "alex-x86_64-linux"
      and .system == "x86_64-linux"
      and .resolvedRevision == "0123456789abcdef0123456789abcdef01234567"
      and .status == "built"
      and (.packages.added | map(.changeKind) == ["added"])
      and (.packages.updated | map(.changeKind) == ["upgraded", "downgraded", "changed"])
      and (.packages.removed | map(.changeKind) == ["removed"])
      and .storePaths == {previous:7529,resulting:7536,added:5054,removed:5047}
      and .closure == {previous:"1.50 GiB",resulting:"1.49 GiB",delta:"-5.59 MiB"}
      and .generations.previous == "/nix/store/old-home-manager-generation"
      and .generations.new == "/nix/store/new-home-manager-generation"
      and ([.technical[] | contains("Finished at") or contains("⏱")] | any | not)
    ' <<< "$preview" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

    atyrode apply --plan --json | jq -e '
      .source == "remote"
      and .revision == "feedfacefeed"
      and .resolvedRevision == "feedfacefeedfacefeedfacefeedfacefeedface"
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

    # The user manager, not the invoking terminal, owns a mutating apply. Kill
    # the waiting CLI while nh is blocked and prove the private worker still
    # publishes its result. The fixed transient-unit name also rejects overlap.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    rm -f "$TMPDIR/nh-started"
    export _ATYRODE_TEST_SYSTEMD_AVAILABLE=1
    export ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run"
    export ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl"
    ATYRODE_NH_DELAY=1 atyrode apply --repo "$HOME/nix-dotfiles" \
      >"$TMPDIR/detached-apply.out" 2>"$TMPDIR/detached-apply.err" &
    apply_caller="$!"
    for _ in $(seq 1 100); do
      [[ ! -e "$TMPDIR/nh-started" ]] || break
      sleep 0.05
    done
    test -e "$TMPDIR/nh-started"
    if atyrode apply --repo "$HOME/nix-dotfiles" \
      >"$TMPDIR/overlap.out" 2>"$TMPDIR/overlap.err"; then
      echo 'overlapping apply unexpectedly succeeded' >&2
      exit 1
    fi
    grep -F 'another apply job is active' "$TMPDIR/overlap.err" >/dev/null
    kill "$apply_caller"
    wait "$apply_caller" 2>/dev/null || true
    job_id="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    for _ in $(seq 1 100); do
      [[ ! -e "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/result.json" ]] || break
      sleep 0.05
    done
    test -e "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/result.json"
    jq -e '.phase == "succeeded" and .exitCode == 0' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/result.json" >/dev/null
    apply_status="$(atyrode apply-status "$job_id" --json)"
    jq -e '
      .jobId == $job
      and .unit == "atyrode-apply.service"
      and .phase == "succeeded"
      and .result.exitCode == 0
      and (.output | contains("detached activation completed"))
    ' --arg job "$job_id" <<<"$apply_status" >/dev/null
    grep -F -- '--collect' "$TMPDIR/fake-systemd/run-args" >/dev/null
    grep -F -- '--service-type=exec' "$TMPDIR/fake-systemd/run-args" >/dev/null
    grep -F -- '/bin/atyrode __apply-job' "$TMPDIR/fake-systemd/run-args" >/dev/null
    if grep -F -- '/bin/.atyrode-wrapped __apply-job' "$TMPDIR/fake-systemd/run-args" >/dev/null; then
      echo 'manager worker bypassed the packaged PATH wrapper' >&2
      exit 1
    fi
    test "$(wc -l < "$TMPDIR/fake-systemd/run-args")" = 1
    if grep -F -- '--scope' "$TMPDIR/fake-systemd/run-args" >/dev/null; then
      echo 'apply supervision used a caller-owned systemd scope' >&2
      exit 1
    fi
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = alex-x86_64-linux
    unset _ATYRODE_TEST_SYSTEMD_AVAILABLE ATYRODE_SYSTEMD_RUN ATYRODE_SYSTEMCTL

    atyrode apply --ref 0123456789012345678901234567890123456789 --plan --json | jq -e '
      .source == "remote"
      and .revision == "012345678901"
      and .resolvedRevision == "0123456789012345678901234567890123456789"
    ' >/dev/null

    if atyrode apply --ref main --repo "$HOME/nix-dotfiles" --plan >/dev/null 2>&1; then
      echo '--ref with --repo unexpectedly succeeded' >&2
      exit 1
    fi

    if atyrode apply alex-aarch64-linux --plan >/dev/null 2>&1; then
      echo 'cross-system host selection unexpectedly succeeded' >&2
      exit 1
    fi

    # NixOS-WSL is a two-phase control plane: Nix activates the guest, then the
    # guest calls the native winget.exe as the interactive Windows user. Exercise
    # plan purity, exact-ID installation, channel-conflict refusal, and the
    # top-level orchestration without touching a real Windows machine.
    mkdir -p "$TMPDIR/winget-state"
    cat > "$TMPDIR/bin/winget.exe" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" >> "$WINGET_LOG"
    case "''${1:-}" in
      --version)
        printf 'v1.11.510\n'
        ;;
      list)
        [[ "''${WINGET_QUERY_ERROR:-0}" != 1 ]] || exit 45
        package_id=""
        while [[ "$#" -gt 0 ]]; do
          if [[ "$1" == --id ]]; then
            package_id="$2"
            break
          fi
          shift
        done
        case "$package_id" in
          Zen-Team.Zen-Browser.Twilight) [[ -f "$WINGET_STATE/twilight" ]] && exit 0 || exit 20 ;;
          Zen-Team.Zen-Browser) [[ -f "$WINGET_STATE/stable" ]] && exit 0 || exit 20 ;;
          DEVCOM.JetBrainsMonoNerdFont) [[ -f "$WINGET_STATE/jetbrains-nerd-font" ]] && exit 0 || exit 20 ;;
          *) exit 64 ;;
        esac
        ;;
      install)
        case "$*" in
          *'--id Zen-Team.Zen-Browser.Twilight --exact --source winget'*)
            touch "$WINGET_STATE/twilight"
            ;;
          *'--id DEVCOM.JetBrainsMonoNerdFont --exact --source winget'*)
            touch "$WINGET_STATE/jetbrains-nerd-font"
            ;;
          *) exit 64 ;;
        esac
        ;;
      *)
        exit 64
        ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/winget.exe"
    export ATYRODE_WINGET="$TMPDIR/bin/winget.exe"
    export WINGET_LOG="$TMPDIR/winget.log"
    export WINGET_STATE="$TMPDIR/winget-state"
    export _ATYRODE_TEST_WSL=1
    rm -f "$WINGET_STATE/twilight" "$WINGET_STATE/stable" "$WINGET_STATE/jetbrains-nerd-font"
    export _ATYRODE_TEST_HOSTNAME=atyrode-wsl
    : > "$WINGET_LOG"

    windows_plan="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '
      .schemaVersion == 2
      and .host == "alex-x86_64-linux-wsl"
      and .wingetVersion == "v1.11.510"
      and .ready
      and (.converged | not)
      and .changes == 2
      and (.packages | length) == 2
      and ([.packages[] | select(
        .id == "Zen-Team.Zen-Browser.Twilight"
        and .status == "missing"
        and (.installed | not)
        and .detectedConflicts == []
      )] | length == 1)
      and ([.packages[] | select(
        .id == "DEVCOM.JetBrainsMonoNerdFont"
        and .status == "missing"
        and (.installed | not)
        and .detectedConflicts == []
      )] | length == 1)
      and (.transactional | not)
      and .mutationBoundary == "WinGet package state is native Windows state; Nix generations and rollback do not cover it"
    ' <<<"$windows_plan" >/dev/null \
      || { echo "Windows plan contract is wrong: $windows_plan" >&2; exit 1; }
    test ! -e "$WINGET_STATE/twilight"
    test ! -e "$WINGET_STATE/jetbrains-nerd-font"
    grep -qF 'list --id Zen-Team.Zen-Browser.Twilight --exact --accept-source-agreements --disable-interactivity' \
      "$WINGET_LOG"

    rm -f "$TMPDIR/nh-args"
    wsl_apply_plan="$(atyrode apply alex-x86_64-linux-wsl --repo "$HOME/nix-dotfiles" --plan --json)"
    jq -e '
      .activation == "nixos-wsl"
      and .backend == "nh-os"
      and .windowsPlan.ready
      and (.windowsPlan.converged | not)
      and .mutationBoundary == "NixOS activation followed by non-transactional native Windows reconciliation"
    ' <<<"$wsl_apply_plan" >/dev/null \
      || { echo "WSL apply plan contract is wrong: $wsl_apply_plan" >&2; exit 1; }
    test ! -e "$TMPDIR/nh-args"
    test ! -e "$WINGET_STATE/twilight"

    wsl_apply="$(atyrode apply alex-x86_64-linux-wsl --repo "$HOME/nix-dotfiles" --json)"
    jq -e '.activation == "nixos-wsl" and .backend == "nh-os"' <<<"$wsl_apply" >/dev/null
    grep -Fx -- "os switch $HOME/nix-dotfiles#alex-x86_64-linux-wsl --diff always" \
      "$TMPDIR/nh-args" >/dev/null
    grep -F -- 'install --id Zen-Team.Zen-Browser.Twilight --exact --source winget' \
      "$WINGET_LOG" >/dev/null
    grep -F -- 'install --id DEVCOM.JetBrainsMonoNerdFont --exact --source winget' \
      "$WINGET_LOG" >/dev/null
    test -f "$WINGET_STATE/twilight"
    test -f "$WINGET_STATE/jetbrains-nerd-font"
    converged_windows="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '.ready and .converged and .changes == 0 and all(.packages[]; .status == "installed")' \
      <<<"$converged_windows" >/dev/null \
      || { echo "Windows plan did not converge after apply: $converged_windows" >&2; exit 1; }

    rm -f "$WINGET_STATE/twilight"
    touch "$WINGET_STATE/stable"
    : > "$WINGET_LOG"
    set +e
    blocked_plan="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    windows_blocked_plan_status="$?"
    set -e
    test "$windows_blocked_plan_status" = 69
    jq -e '
      (.ready | not)
      and ([.packages[] | select(
        .id == "Zen-Team.Zen-Browser.Twilight"
        and .status == "blocked"
        and (.detectedConflicts | index("Zen-Team.Zen-Browser"))
        and (.remediation | contains("explicitly uninstall the stable Zen package"))
      )] | length == 1)
    ' <<<"$blocked_plan" >/dev/null \
      || { echo "stable/Twilight conflict was not reported: $blocked_plan" >&2; exit 1; }
    set +e
    atyrode windows apply alex-x86_64-linux-wsl --json \
      > "$TMPDIR/windows-blocked.out" 2> "$TMPDIR/windows-blocked.err"
    windows_blocked_status="$?"
    set -e
    test "$windows_blocked_status" = 69
    ! grep -qF 'install --id' "$WINGET_LOG"
    test ! -e "$WINGET_STATE/twilight"

    set +e
    ATYRODE_WINGET="$TMPDIR/bin/missing-winget.exe" \
      atyrode windows plan alex-x86_64-linux-wsl --json \
      > "$TMPDIR/windows-unavailable.out" 2> "$TMPDIR/windows-unavailable.err"
    windows_unavailable_status="$?"
    set -e
    test "$windows_unavailable_status" = 69
    test ! -s "$TMPDIR/windows-unavailable.out"
    grep -qF 'winget.exe is unavailable through WSL interop' "$TMPDIR/windows-unavailable.err"

    set +e
    WINGET_QUERY_ERROR=1 atyrode windows plan alex-x86_64-linux-wsl --json \
      > "$TMPDIR/windows-query-error.out" 2> "$TMPDIR/windows-query-error.err"
    windows_query_error_status="$?"
    set -e
    test "$windows_query_error_status" = 69
    test ! -s "$TMPDIR/windows-query-error.out"
    grep -qF 'winget.exe could not query installed package Zen-Team.Zen-Browser.Twilight (exit 45)' \
      "$TMPDIR/windows-query-error.err"
    ! grep -qF 'install --id' "$WINGET_LOG"

    unset ATYRODE_WINGET WINGET_LOG WINGET_STATE _ATYRODE_TEST_WSL
    export _ATYRODE_TEST_HOSTNAME=fixture-linux
    printf '%s\n' alex-x86_64-linux > "$XDG_STATE_HOME/atyrode/dotfiles-config"

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
    server_result="$(atyrode doctor system fixture-nixos --json)"
    jq -e '
      .ok
      and ([.checks[] | select(.id == "login-shell" or .id == "nix-daemon" or
          .id == "nix-policy" or .id == "container-engine" or
          .id == "antivirus-data" or .id == "device-permissions") | .owner]
        | all(. == "nixos"))
      and (.checks[] | select(.id == "nix-policy") | .expected.trustedUsers) == ["fixture", "root"]
    ' <<< "$server_result" >/dev/null

    # NixOS can install a generated wrapped Zsh as the account shell. The
    # wrapper is system-owned and executable but is not itself listed in
    # /etc/shells, so diagnostics accept this NixOS-specific representation.
    server_wrapped_ready="$TMPDIR/server-wrapped-ready.json"
    jq '.loginShell = {
      path:"/nix/store/00000000000000000000000000000000-wrapped-zsh/wrapper",
      executable:true,
      listed:false
    }' "$linux_ready" > "$server_wrapped_ready"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$server_wrapped_ready"
    atyrode doctor system fixture-nixos --json | jq -e '
      .ok and (.checks[] | select(.id == "login-shell") | .status) == "ok"
    ' >/dev/null

    # NixOS-WSL is selected by its activation backend, not by adding the
    # unrelated server capability to a workstation host.
    export _ATYRODE_TEST_USER=alex
    export _ATYRODE_TEST_HOSTNAME=atyrode-wsl
    wsl_result="$(atyrode doctor system alex-x86_64-linux-wsl --json)"
    jq -e '
      .ok
      and (.checks[] | select(.id == "login-shell") | .status) == "ok"
      and ([.checks[] | select(.id == "login-shell" or .id == "nix-daemon" or
          .id == "nix-policy") | .owner] | all(. == "nixos"))
    ' <<< "$wsl_result" >/dev/null
    export _ATYRODE_TEST_USER=fixture
    export _ATYRODE_TEST_HOSTNAME=fixture-linux

    server_wrong_wrapper="$TMPDIR/server-wrong-wrapper.json"
    jq '.loginShell = {
      path:"/nix/store/00000000000000000000000000000000-wrapped-bash/wrapper",
      executable:true,
      listed:false
    }' "$linux_ready" > "$server_wrong_wrapper"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$server_wrong_wrapper"
    if atyrode doctor system fixture-nixos --json > "$TMPDIR/server-wrong-wrapper.out"; then
      echo 'a non-Zsh NixOS wrapper unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.checks[] | select(.id == "login-shell") | .code) == "login-shell-mismatch"
    ' "$TMPDIR/server-wrong-wrapper.out" >/dev/null

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
    help="$(atyrode --help)"
    grep -qF 'then prints preflight metadata without invoking nh; --dry-run invokes the normal' <<<"$help"
    grep -qF 'nh switch backend with --dry; --preview-json runs that dry backend and emits its' <<<"$help"
    grep -qF 'atyrode capabilities list [--json]' <<<"$help"
    grep -qF 'atyrode capabilities show [HOST] [--json]' <<<"$help"
    grep -qF 'atyrode infra setup|plan|apply [--repo PATH] [--json] [--yes]' <<<"$help"
    grep -qF 'atyrode vault get NAME' <<<"$help"
    grep -qF 'atyrode vault put NAME' <<<"$help"

    mkdir "$out"
  ''
