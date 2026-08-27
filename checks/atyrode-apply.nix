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
    for override in ATYRODE_FETCH ATYRODE_MSIEXEC ATYRODE_WSLPATH ATYRODE_LOCALAPPDATA ATYRODE_POWERSHELL ATYRODE_SHA256SUM; do
      set +e
      env -u ATYRODE_NH -u ATYRODE_NIX_ENV -u ATYRODE_GIT -u ATYRODE_GEN_PROFILE \
        "$override=/bin/true" ${productionAtyrode}/bin/atyrode \
        windows apply alex-x86_64-linux-wsl \
        > /dev/null 2> "$TMPDIR/prod-windows-guard.err"
      prod_windows_guard_status="$?"
      set -e
      test "$prod_windows_guard_status" = 64
      grep -qF "$override is set" "$TMPDIR/prod-windows-guard.err"
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
    # A successful apply with no backup env file surfaces the setup pointer
    # (non-interactive here, so no prompt) without failing the activation.
    grep -qF 'session backup not configured; set up with: atyrode backup setup' \
      "$TMPDIR/apply-success.err"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = alex-x86_64-linux
    test -z "$(find "$XDG_STATE_HOME/atyrode" -name '.dotfiles-config.*' -print -quit)"
    test "$(cat "$TMPDIR/nh-locale")" = C.UTF-8

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
          raphamorim.rio)
            [[ -f "$WINGET_STATE/rio-version" ]] || exit 20
            printf 'Name Id             Version Source\n-----------------------------------\nRio  raphamorim.rio %-7s winget\n' "$(cat "$WINGET_STATE/rio-version")"
            ;;
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
    cat > "$TMPDIR/bin/powershell.exe" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" >> "$POWERSHELL_LOG"
    case "$*" in
      *Get-ItemProperty*)
        if [[ -f "$WINGET_STATE/rio-high-performance-gpu" ]]; then
          printf 'true\r\n'
        else
          printf 'false\r\n'
        fi
        ;;
      *New-ItemProperty*)
        touch "$WINGET_STATE/rio-high-performance-gpu"
        ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/fetch" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    [[ "$1" == -fsSL && "$3" == -o ]] || exit 64
    printf '%s\n' "$RIO_FETCH_CONTENT" > "$4"
    EOF
    cat > "$TMPDIR/bin/msiexec.exe" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" >> "$MSI_LOG"
    printf '0.4.7\n' > "$WINGET_STATE/rio-version"
    EOF
    cat > "$TMPDIR/bin/wslpath" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    [[ "$1" == -w ]] || exit 64
    printf 'C:\\mock\\rio-installer-x86_64.msi\n'
    EOF
    cat > "$TMPDIR/bin/sha256sum" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    case "$(cat "$1")" in
      good) printf '%s  %s\n' 4b635ec754fadc24a8c58f47af04e07047f448e43e24fc3131d5de28dad0d55d "$1" ;;
      *) printf '%064d  %s\n' 0 "$1" ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/fetch" "$TMPDIR/bin/msiexec.exe" "$TMPDIR/bin/powershell.exe" "$TMPDIR/bin/wslpath" "$TMPDIR/bin/sha256sum"
    export ATYRODE_WINGET="$TMPDIR/bin/winget.exe"
    export WINGET_LOG="$TMPDIR/winget.log"
    export WINGET_STATE="$TMPDIR/winget-state"
    export _ATYRODE_TEST_WSL=1
    export ATYRODE_FETCH="$TMPDIR/bin/fetch"
    export ATYRODE_MSIEXEC="$TMPDIR/bin/msiexec.exe"
    export ATYRODE_WSLPATH="$TMPDIR/bin/wslpath"
    export ATYRODE_POWERSHELL="$TMPDIR/bin/powershell.exe"
    export ATYRODE_LOCALAPPDATA="$TMPDIR/windows-localappdata"
    export ATYRODE_SHA256SUM="$TMPDIR/bin/sha256sum"
    export MSI_LOG="$TMPDIR/msiexec.log"
    export POWERSHELL_LOG="$TMPDIR/powershell.log"
    export RIO_FETCH_CONTENT=good
    mkdir -p "$ATYRODE_LOCALAPPDATA"
    rm -f "$WINGET_STATE/twilight" "$WINGET_STATE/stable" "$WINGET_STATE/jetbrains-nerd-font" "$WINGET_STATE/rio-high-performance-gpu" "$WINGET_STATE/rio-version"
    export _ATYRODE_TEST_HOSTNAME=atyrode-wsl
    rm -f "$WINGET_STATE/twilight" "$WINGET_STATE/stable"
    : > "$WINGET_LOG"

    windows_plan="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '
      .schemaVersion == 2
      and .host == "alex-x86_64-linux-wsl"
      and .wingetVersion == "v1.11.510"
      and .ready
      and (.converged | not)
      and .changes == 3
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
      and ([.packages[] | select(
        .id == "raphamorim.rio"
        and .source == "github-release"
        and .pinnedVersion == "0.4.7"
        and .installedVersion == null
        and .installedVersionSource == "absent"
        and (.configMatches | not)
        and (.graphicsPreferenceMatches | not)
        and .status == "missing"
      )] | length == 1)
      and (.transactional | not)
      and .mutationBoundary == "WinGet, Rio MSI, Windows graphics preferences, and Rio runtime state are native Windows state; Nix generations and rollback do not cover them"
    ' <<<"$windows_plan" >/dev/null \
      || { echo "Windows plan contract is wrong: $windows_plan" >&2; exit 1; }
    test ! -e "$WINGET_STATE/twilight"
    test ! -e "$WINGET_STATE/jetbrains-nerd-font"
    test ! -e "$ATYRODE_LOCALAPPDATA/rio"
    test ! -e "$WINGET_STATE/rio-high-performance-gpu"
    grep -qF 'list --id Zen-Team.Zen-Browser.Twilight --exact --accept-source-agreements --disable-interactivity' \
      "$WINGET_LOG"

    # The downloader must not pass an unverified MSI to Windows or leave a Rio
    # stamp/config behind. Mark the WinGet packages present so this isolates Rio.
    touch "$WINGET_STATE/twilight"
    touch "$WINGET_STATE/jetbrains-nerd-font"
    RIO_FETCH_CONTENT=wrong
    set +e
    atyrode windows apply alex-x86_64-linux-wsl --json \
      > "$TMPDIR/rio-hash-mismatch.out" 2> "$TMPDIR/rio-hash-mismatch.err"
    rio_hash_mismatch_status="$?"
    set -e
    test "$rio_hash_mismatch_status" = 65
    grep -qF 'downloaded installer SHA256 does not match the lock' "$TMPDIR/rio-hash-mismatch.err"
    test ! -e "$ATYRODE_LOCALAPPDATA/rio/atyrode-install-version"
    test ! -e "$ATYRODE_LOCALAPPDATA/rio/config.toml"
    test ! -s "$MSI_LOG"
    test ! -e "$WINGET_STATE/rio-high-performance-gpu"
    rm -f "$WINGET_STATE/twilight" "$WINGET_STATE/jetbrains-nerd-font"
    RIO_FETCH_CONTENT=good

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
    test -f "$WINGET_STATE/rio-high-performance-gpu"
    converged_windows="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '.ready and .converged and .changes == 0 and all(.packages[]; .status == "installed")' \
      <<<"$converged_windows" >/dev/null \
      || { echo "Windows plan did not converge after apply: $converged_windows" >&2; exit 1; }
    grep -Fx -- '/i C:\mock\rio-installer-x86_64.msi /qn /norestart' "$MSI_LOG" >/dev/null
    cmp -s ${../home/rio/config.toml} "$ATYRODE_LOCALAPPDATA/rio/config.toml"
    test "$(cat "$ATYRODE_LOCALAPPDATA/rio/atyrode-install-version")" = 0.4.7
    grep -qF 'New-ItemProperty' "$POWERSHELL_LOG"
    # Config-only drift is repaired atomically without downloading or invoking
    # the MSI again.
    printf 'bad config\n' > "$ATYRODE_LOCALAPPDATA/rio/config.toml"
    : > "$MSI_LOG"
    atyrode windows apply alex-x86_64-linux-wsl --json >/dev/null
    test ! -s "$MSI_LOG"
    cmp -s ${../home/rio/config.toml} "$ATYRODE_LOCALAPPDATA/rio/config.toml"

    # Graphics-preference drift is repaired without reinstalling Rio or changing
    # its config. Windows remains the final arbiter when no discrete GPU exists.
    rm -f "$WINGET_STATE/rio-high-performance-gpu"
    graphics_drift_plan="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '[.packages[] | select(
      .id == "raphamorim.rio"
      and .status == "graphics-preference-drift"
      and (.graphicsPreferenceMatches | not)
      and .graphicsPreference.mode == "high-performance"
      and .graphicsPreference.registryValue == "GpuPreference=2;"
    )] | length == 1' <<<"$graphics_drift_plan" >/dev/null
    : > "$MSI_LOG"
    atyrode windows apply alex-x86_64-linux-wsl --json >/dev/null
    test -f "$WINGET_STATE/rio-high-performance-gpu"
    test ! -s "$MSI_LOG"
    cmp -s ${../home/rio/config.toml} "$ATYRODE_LOCALAPPDATA/rio/config.toml"
    # Winget/ARP is authoritative: a stale pinned stamp cannot mask an older
    # external MSI install, which follows the natural MSI upgrade path.
    printf '0.4.7\n' > "$ATYRODE_LOCALAPPDATA/rio/atyrode-install-version"
    printf '0.4.6\n' > "$WINGET_STATE/rio-version"
    rio_upgrade_plan="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '[.packages[] | select(.id == "raphamorim.rio" and .status == "upgrade" and .installedVersion == "0.4.6" and .installedVersionSource == "winget" and .pinnedVersion == "0.4.7")] | length == 1' \
      <<<"$rio_upgrade_plan" >/dev/null
    # An uninstall cannot be masked either: winget reporting no installed
    # Rio (exit 20) is authoritative absence, and a leftover pinned stamp
    # must never be consulted.
    rm -f "$WINGET_STATE/rio-version"
    rio_uninstalled_plan="$(atyrode windows plan alex-x86_64-linux-wsl --json)"
    jq -e '[.packages[] | select(.id == "raphamorim.rio" and .status == "missing" and .installedVersion == null and .installedVersionSource == "absent")] | length == 1' \
      <<<"$rio_uninstalled_plan" >/dev/null
    printf '0.4.6\n' > "$WINGET_STATE/rio-version"
    : > "$MSI_LOG"
    atyrode windows apply alex-x86_64-linux-wsl --json >/dev/null
    grep -Fx -- '/i C:\mock\rio-installer-x86_64.msi /qn /norestart' "$MSI_LOG" >/dev/null
    test "$(cat "$ATYRODE_LOCALAPPDATA/rio/atyrode-install-version")" = 0.4.7

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
    grep -qF 'atyrode backup setup' <<<"$help"
    grep -qF 'atyrode backup status [--json]' <<<"$help"
    grep -qF 'atyrode backup now' <<<"$help"

    mkdir "$out"
  ''
