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
      pkgs.gh
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
    if [[ "$*" == *"home switch"* && "$*" == *" --dry"* ]]; then
      printf '\033[?25l⠋ Building\r⏱ 0s\rFinished at 14:18:57 after 0s\n'
      printf '\033[1m<<<\033[0m /nix/store/old-home-manager-generation\n'
      printf '\033[1m>>>\033[0m /nix/store/new-home-manager-generation\n\n'
      printf 'CHANGED\n[U.] alpha 1.0 -> 2.0, +9.67 KiB\n[D.] beta 3.0 -> 2.5, -1.00 MiB\n[C.] source -9.67 KiB\n\n'
      printf 'ADDED\n[A+] gamma 4.0, +2.00 MiB\n\n'
      printf 'REMOVED\n[R-] delta 5.0, -7.00 MiB\n\n'
      printf 'PATHS: 7529 -> 7536 (+5054, -5047)\nSIZE: 1.50 GiB -> 1.49 GiB\nDIFF: -5.59 MiB\033[?25h\n'
    elif [[ "''${ATYRODE_NH_NOISE:-0}" == 1 ]]; then
      # Reproduce nh 4.4.1 clean's real output shape: a verbose evaluation plan
      # (Welcome/legend/one line per gcroot), the benign root-owned gcroots
      # permission flood, and one real (non-permission) error — so the check can
      # prove the plan and flood are folded while a genuine error survives.
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
      # Under elevation nh removes the same daemon-owned roots cleanly (no paired
      # PermissionDenied), so the fold counts them as reaped (removals − failures)
      # rather than echoing one line per root.
      echo '- OK  /home/alex/.local/state/nix/profiles/profile-9-link'
      echo '> Removing /nix/var/nix/gcroots/auto/lvi04m7mn76ymzgzcx5rrifj5019psvd'
      echo '> Removing /nix/var/nix/gcroots/auto/phm61mw9l2zpvj3fj6pmmyk22b1l3qg8'
    fi
    [[ "''${ATYRODE_NH_FAIL:-0}" != 1 ]]
    EOF
    # Stub nix-env's generation listing (clean --json / generations read it).
    cat > "$TMPDIR/bin/nix-env" <<'EOF'
    #!${pkgs.runtimeShell}
    if [[ "''${ATYRODE_NIX_ENV_MALFORMED:-0}" == 1 ]]; then
      echo 'not a generation row'
      exit 0
    fi
    case "$*" in
      *--list-generations*)
        echo "  1   2026-05-01 10:00:00"
        echo "  2   2026-06-01 10:00:00"
        echo "  3   2026-07-01 10:00:00   (current)" ;;
    esac
    EOF
    cat > "$TMPDIR/bin/omp" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/omp-args"
    case "$*" in
      gc)
        printf 'GC dry-run: 2 stale sessions, 4096 bytes reclaimable\n'
        ;;
      'worktree clear --dry-run')
        printf 'would remove %s\n' "$HOME/.omp/wt/stale"
        ;;
      *)
        printf 'unexpected omp arguments: %s\n' "$*" >&2
        exit 64
        ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/git" "$TMPDIR/bin/nh" "$TMPDIR/bin/nix-env" "$TMPDIR/bin/omp"
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

    # doctor git is read-only and reports classifications only. The fixture
    # gives it a real Git config, repository, SSH agent, and public key files;
    # private fixture material remains inside TMPDIR.
    (
      export HOME="$TMPDIR/git-doctor-home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export GH_CONFIG_DIR="$XDG_CONFIG_HOME/gh"
      export GIT_CONFIG_GLOBAL="$XDG_CONFIG_HOME/git/config"
      export GIT_CONFIG_NOSYSTEM=1
      unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
      mkdir -p "$HOME/.ssh" "$XDG_CONFIG_HOME/git" "$GH_CONFIG_DIR" "$TMPDIR/git-doctor-repo"

      git_doctor=${pkgs.gitMinimal}/bin/git
      read -r _ signing_type signing_blob < ${../home/git-allowed-signers}
      printf '%s %s fixture-signing-key\n' "$signing_type" "$signing_blob" \
        > "$HOME/.ssh/id_ed25519_git_signing.pub"
      chmod 0644 "$HOME/.ssh/id_ed25519_git_signing.pub"
      cp ${../home/git-allowed-signers} "$XDG_CONFIG_HOME/git/allowed_signers"
      chmod 0644 "$XDG_CONFIG_HOME/git/allowed_signers"

      "$git_doctor" config --global user.signingKey "$HOME/.ssh/id_ed25519_git_signing.pub"
      "$git_doctor" config --global gpg.format ssh
      "$git_doctor" config --global gpg.ssh.allowedSignersFile "$XDG_CONFIG_HOME/git/allowed_signers"
      "$git_doctor" config --global --add credential.https://github.com.helper ""
      "$git_doctor" config --global --add credential.https://github.com.helper \
        "${pkgs.gh}/bin/gh auth git-credential"
      "$git_doctor" config --global 'url.git@github.com:.pushInsteadOf' https://github.com/
      "$git_doctor" -C "$TMPDIR/git-doctor-repo" init -q
      "$git_doctor" -C "$TMPDIR/git-doctor-repo" remote add origin \
        https://github.com/atyrode/fixture.git

      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f "$TMPDIR/agent-key"
      eval "$(${pkgs.openssh}/bin/ssh-agent -s)" >/dev/null
      trap '${pkgs.openssh}/bin/ssh-agent -k >/dev/null 2>&1 || true' EXIT
      ${pkgs.openssh}/bin/ssh-add "$TMPDIR/agent-key" >/dev/null 2>&1

      cd "$TMPDIR/git-doctor-repo"
      git_result="$(atyrode doctor git --json)"
      jq -e '
        .schemaVersion == 1
        and .command == "doctor git"
        and .ok
        and .mutationBoundary == "read-only probes"
        and (.checks | map(.id)) == [
          "git-configuration",
          "ssh-agent",
          "ssh-agent-keys",
          "signing-key",
          "allowed-signers",
          "remote-protocol",
          "credential-helper-plaintext",
          "credential-file-plaintext",
          "gh-credential-helper",
          "gh-auth-storage"
        ]
        and (.checks[] | select(.id == "allowed-signers") | .actual.signingKeyAuthorized)
        and (.checks[] | select(.id == "remote-protocol") | .actual.httpsFetchUrls) == 1
        and (.checks[] | select(.id == "remote-protocol") | .actual.sshPushUrls) == 1
        and (.checks[] | select(.id == "gh-credential-helper") | .status) == "ok"
        and (.checks[] | select(.id == "gh-auth-storage") | .status) == "not-applicable"
      ' <<<"$git_result" >/dev/null

      "$git_doctor" config --global --unset-all 'url.git@github.com:.pushInsteadOf'
      "$git_doctor" config --global --unset-all credential.https://github.com.helper
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-https.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "remote-protocol") | .status) == "warning"
        and (.checks[] | select(.id == "gh-credential-helper") | .status) == "failed"
      ' "$TMPDIR/git-doctor-https.json" >/dev/null
      "$git_doctor" config --global --add credential.https://github.com.helper ""
      "$git_doctor" config --global --add credential.https://github.com.helper \
        "${pkgs.gh}/bin/gh auth git-credential"
      "$git_doctor" config --global 'url.git@github.com:.pushInsteadOf' https://github.com/

      "$git_doctor" config --global credential.helper store
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-store.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "credential-helper-plaintext") | .status) == "failed"
      ' "$TMPDIR/git-doctor-store.json" >/dev/null
      "$git_doctor" config --global --unset-all credential.helper

      printf 'https://fixture:placeholder@github.com\n' > "$HOME/.git-credentials"
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-credential-file.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "credential-file-plaintext") | .status) == "failed"
      ' "$TMPDIR/git-doctor-credential-file.json" >/dev/null
      rm "$HOME/.git-credentials"

      printf '# drift\n' >> "$XDG_CONFIG_HOME/git/allowed_signers"
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-signers.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "allowed-signers") | .status) == "failed"
      ' "$TMPDIR/git-doctor-signers.json" >/dev/null
      cp ${../home/git-allowed-signers} "$XDG_CONFIG_HOME/git/allowed_signers"

      chmod 0666 "$HOME/.ssh/id_ed25519_git_signing.pub"
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-key-mode.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "signing-key") | .actual.permissionsSafe) == false
      ' "$TMPDIR/git-doctor-key-mode.json" >/dev/null
      chmod 0644 "$HOME/.ssh/id_ed25519_git_signing.pub"

      mkdir -p "$TMPDIR/git-doctor-bin"
    cat > "$TMPDIR/git-doctor-bin/gh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' '{"hosts":{"github.com":[{"tokenSource":"keyring"}]}}'
    EOF
      chmod +x "$TMPDIR/git-doctor-bin/gh"
      export PATH="$TMPDIR/git-doctor-bin:$PATH"
      printf '%s\n' 'github.com:' '    users:' '        atyrode:' \
        > "$GH_CONFIG_DIR/hosts.yml"
      keyring_result="$(atyrode doctor git --json)"
      jq -e '
        .ok
        and (.checks[] | select(.id == "gh-auth-storage") | .status) == "ok"
        and (.checks[] | select(.id == "gh-auth-storage") | .actual.keyringAccountCount) == 1
      ' <<<"$keyring_result" >/dev/null

    cat > "$GH_CONFIG_DIR/hosts.yml" <<'EOF'
    github.com:
        oauth_token: fixture-token-must-not-appear
    EOF
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-gh-plaintext.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "gh-auth-storage") | .status) == "failed"
        and (.checks[] | select(.id == "gh-auth-storage") | .actual.plaintextTokenFile)
      ' "$TMPDIR/git-doctor-gh-plaintext.json" >/dev/null
      ! grep -qF fixture-token-must-not-appear "$TMPDIR/git-doctor-gh-plaintext.json"
      rm "$GH_CONFIG_DIR/hosts.yml"

      ${pkgs.openssh}/bin/ssh-agent -k >/dev/null
      unset SSH_AUTH_SOCK SSH_AGENT_PID
      trap - EXIT
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-no-agent.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "ssh-agent") | .status) == "failed"
        and (.checks[] | select(.id == "ssh-agent-keys") | .status) == "failed"
      ' "$TMPDIR/git-doctor-no-agent.json" >/dev/null

      set +e
      atyrode doctor git --unknown >/dev/null 2>&1
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 64
    )
    atyrode apply --repo "$HOME/nix-dotfiles" --plan --json | jq -e '
      .host == "alex-x86_64-linux"
      and .backend == "nh-home"
      and .source == "local"
      and .revision == "0123456789ab"
      and .resolvedRevision == "0123456789abcdef0123456789abcdef01234567"
      and .mutationBoundary == "activation only after preflight"
    ' >/dev/null
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"

    LC_CTYPE=UTF-8 atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null
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
          StablyAI.Orca) [[ -f "$WINGET_STATE/orca" ]] && exit 0 || exit 20 ;;
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
          *'--id StablyAI.Orca --exact --source winget'*)
            touch "$WINGET_STATE/orca"
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
    rm -f "$WINGET_STATE/twilight" "$WINGET_STATE/stable" "$WINGET_STATE/jetbrains-nerd-font" "$WINGET_STATE/orca" "$WINGET_STATE/rio-high-performance-gpu" "$WINGET_STATE/rio-version"
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
      and .changes == 4
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
        .id == "StablyAI.Orca"
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
    test ! -e "$WINGET_STATE/orca"
    test ! -e "$ATYRODE_LOCALAPPDATA/rio"
    test ! -e "$WINGET_STATE/rio-high-performance-gpu"
    grep -qF 'list --id Zen-Team.Zen-Browser.Twilight --exact --accept-source-agreements --disable-interactivity' \
      "$WINGET_LOG"

    # The downloader must not pass an unverified MSI to Windows or leave a Rio
    # stamp/config behind. Mark the WinGet packages present so this isolates Rio.
    touch "$WINGET_STATE/twilight"
    touch "$WINGET_STATE/jetbrains-nerd-font"
    touch "$WINGET_STATE/orca"
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
    rm -f "$WINGET_STATE/twilight" "$WINGET_STATE/jetbrains-nerd-font" "$WINGET_STATE/orca"
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
    grep -F -- 'install --id StablyAI.Orca --exact --source winget' \
      "$WINGET_LOG" >/dev/null
    test -f "$WINGET_STATE/twilight"
    test -f "$WINGET_STATE/jetbrains-nerd-font"
    test -f "$WINGET_STATE/orca"
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

    # clean folds nh's verbose evaluation plan AND the benign root-owned gcroots
    # permission flood into its own footer, while a genuine (non-permission) error
    # still survives.
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
    noise_out="$(ATYRODE_NH_NOISE=1 atyrode clean --keep 3 2>&1 >/dev/null)"
    unset ATYRODE_NIX_STORE
    grep -qE 'atyrode: .*kept 3 generation' <<<"$noise_out" \
      || { echo "clean must print a legible summary footer: $noise_out" >&2; exit 1; }
    grep -qF 'skipped 2 root-owned GC root(s)' <<<"$noise_out" \
      || { echo "footer must tally skipped gcroots: $noise_out" >&2; exit 1; }
    # A non-root clean cannot unlink the daemon-owned roots, so it names the exact
    # elevated command — an ABSOLUTE nix-store path (here the fake-gc stub) plus
    # --gc, since a bare command is off root's secure_path (atyrode never
    # self-elevates, and the old `sudo atyrode clean` hint was unrunnable there).
    grep -qF 'reap them via' <<<"$noise_out" \
      || { echo "footer must point a non-root clean at an elevated reap: $noise_out" >&2; exit 1; }
    grep -qF "sudo $TMPDIR/bin/fake-gc --gc" <<<"$noise_out" \
      || { echo "reap hint must name an absolute nix-store path + --gc: $noise_out" >&2; exit 1; }
    grep -qF 'sudo atyrode clean' <<<"$noise_out" \
      && { echo 'footer must not print the old unrunnable sudo atyrode clean hint' >&2; exit 1; }
    grep -qF 'gcroots/auto/lvi04m7mn76' <<<"$noise_out" \
      && { echo 'clean must not print individual gcroots permission failures' >&2; exit 1; }
    for folded in 'Welcome to nh clean' 'legend:' 'profile-9-link' 'home-manager-62-link' 'channels-1-link'; do
      grep -qF "$folded" <<<"$noise_out" \
        && { echo "clean must fold nh's verbose plan line: $folded" >&2; exit 1; }
    done
    grep -qF '/nix/store/genuine' <<<"$noise_out" \
      || { echo 'clean must keep real (non-permission) failures' >&2; exit 1; }

    # --verbose passes nh's full evaluation plan through instead of folding it.
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
    verbose_out="$(ATYRODE_NH_NOISE=1 atyrode clean --keep 3 --verbose 2>&1 >/dev/null)"
    unset ATYRODE_NIX_STORE
    for shown in 'Welcome to nh clean' 'profile-9-link' 'home-manager-62-link'; do
      grep -qF "$shown" <<<"$verbose_out" \
        || { echo "--verbose must pass nh's plan line through: $shown" >&2; exit 1; }
    done
    grep -qF 'skipped 2 root-owned GC root(s)' <<<"$verbose_out" \
      || { echo "--verbose must still tally skipped gcroots: $verbose_out" >&2; exit 1; }

    # Under elevation (EUID 0) the same roots are removed cleanly: the footer
    # reports them as reaped, counts (not echoes) them, and drops the sudo hint.
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
    reap_out="$(_ATYRODE_TEST_EUID=0 ATYRODE_NH_REAP=1 atyrode clean --keep 3 2>&1 >/dev/null)"
    unset ATYRODE_NIX_STORE
    grep -qF 'reaped 2 root-owned GC root(s)' <<<"$reap_out" \
      || { echo "elevated clean must report reaped gcroots: $reap_out" >&2; exit 1; }
    grep -qF 'reap them via' <<<"$reap_out" \
      && { echo 'elevated clean must not print the sudo reap hint' >&2; exit 1; }
    grep -qF 'gcroots/auto/lvi04m7mn76' <<<"$reap_out" \
      && { echo 'elevated clean must count reaped roots, not echo them' >&2; exit 1; }

    # clean warns about stray result* symlinks (indirect GC roots pinning whole
    # closures) left by `nix build` without --no-link, and never removes them.
    ln -s /nix/store/deadbeef-stray-closure "$TMPDIR/result"
    ( cd "$TMPDIR"
      export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
      stray_out="$(atyrode clean --keep 3 2>&1 >/dev/null)"
      grep -qF 'stray result symlink(s) still pin closures' <<<"$stray_out" \
        || { echo "clean must warn about stray result roots: $stray_out" >&2; exit 1; }
      grep -qF '/nix/store/deadbeef-stray-closure' <<<"$stray_out" \
        || { echo "clean must name the stray result target: $stray_out" >&2; exit 1; }
      test -L "$TMPDIR/result" \
        || { echo 'clean must not remove the stray result symlink' >&2; exit 1; }
    )
    rm -f "$TMPDIR/result"

    # Interactive clean previews the plan and asks first, so an accidental run can
    # be read and declined before anything is removed (_ATYRODE_TEST_TTY forces the
    # interactive branch under the non-tty harness). Declining changes nothing: the
    # garbage collector is never invoked.
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc"
    rm -f "$TMPDIR/gc-args"
    decline_out="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 atyrode clean --keep 1 2>&1)"
    grep -qF 'is about to' <<<"$decline_out" \
      || { echo "interactive clean must preview the plan: $decline_out" >&2; exit 1; }
    grep -qF 'keep the newest 1 generation(s)' <<<"$decline_out" \
      || { echo "preview must state the keep window: $decline_out" >&2; exit 1; }
    grep -qF 'clean declined — nothing changed' <<<"$decline_out" \
      || { echo "declining must abort the clean: $decline_out" >&2; exit 1; }
    test ! -e "$TMPDIR/gc-args" \
      || { echo 'a declined clean must not collect garbage' >&2; exit 1; }

    # The preview count honours BOTH --keep and --keep-since — it must not promise
    # a removal that keep-since will spare. Stub generations: #1 2026-05-01,
    # #2 2026-06-01, #3 2026-07-01 (current). All decline (n) so nothing runs.
    keep_floor="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 atyrode clean --keep 5 2>&1)"
    grep -qF 'remove 0 of 3 generation(s)' <<<"$keep_floor" \
      || { echo "preview: --keep above the total must spare all: $keep_floor" >&2; exit 1; }
    since_wide="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 atyrode clean --keep 0 --keep-since 100000d 2>&1)"
    grep -qF 'remove 0 of 3 generation(s)' <<<"$since_wide" \
      || { echo "preview: a wide --keep-since must spare recent generations: $since_wide" >&2; exit 1; }
    since_narrow="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 atyrode clean --keep 0 --keep-since 1s 2>&1)"
    grep -qF 'remove 2 of 3 generation(s)' <<<"$since_narrow" \
      || { echo "preview: a 1s --keep-since must count the older generations: $since_narrow" >&2; exit 1; }

    # Accepting proceeds through the collector.
    accept_out="$(printf 'y\n' | _ATYRODE_TEST_TTY=1 atyrode clean --keep 3 2>&1)"
    grep -qF 'is about to' <<<"$accept_out" \
      || { echo "accepted clean must still preview: $accept_out" >&2; exit 1; }
    test -e "$TMPDIR/gc-args" \
      || { echo 'an accepted clean must collect garbage' >&2; exit 1; }
    rm -f "$TMPDIR/gc-args"

    # --yes is the explicit non-interactive path: it skips the prompt even on a tty.
    yes_out="$(_ATYRODE_TEST_TTY=1 atyrode clean --keep 3 --yes </dev/null 2>&1)"
    grep -qF 'is about to' <<<"$yes_out" \
      && { echo '--yes must skip the confirmation preview' >&2; exit 1; }
    test -e "$TMPDIR/gc-args" \
      || { echo '--yes clean must collect garbage without prompting' >&2; exit 1; }
    unset ATYRODE_NIX_STORE
    rm -f "$TMPDIR/gc-args"

    # On a live stderr the collector reports progress and a summary the footer
    # reclaims from. A verbose stub mimics nix-store --gc: a couple of `deleting`
    # lines plus the closing "N store paths deleted, X freed" tally.
    cat > "$TMPDIR/bin/fake-gc-verbose" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" > "$TMPDIR/gc-args"
    echo "deleting '/nix/store/aaaaaaaa-old-closure'"
    echo "deleting '/nix/store/bbbbbbbb-older-closure'"
    echo "42 store paths deleted, 1.5 GiB freed"
    EOF
    chmod +x "$TMPDIR/bin/fake-gc-verbose"
    export ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc-verbose"
    gc_out="$(printf 'y\n' | _ATYRODE_TEST_TTY=1 atyrode clean --keep 3 2>&1)"
    unset ATYRODE_NIX_STORE
    grep -qF '1.5 GiB freed' <<<"$gc_out" \
      || { echo "interactive gc must surface the collector summary: $gc_out" >&2; exit 1; }
    grep -qF 'reclaimed 1.5 GiB' <<<"$gc_out" \
      || { echo "footer must reclaim the size the gc reported: $gc_out" >&2; exit 1; }
    rm -f "$TMPDIR/gc-args"

    # Lifecycle is a read-only fixed-path report. The fixture HOME below is the
    # full probe surface: sessions, dirty/branch/marker live OMP worktrees, a
    # clean stale worktree, malformed state, and caches. Every omp call reaches
    # the PATH stub above; no command in this check can inspect the machine's
    # real state.
    mkdir -p "$TMPDIR/lifecycle-repo" "$HOME/.omp/agent/sessions/project" \
      "$HOME/.omp/wt/dirty" "$HOME/.omp/wt/branch-live" "$HOME/.omp/wt/marker-live" \
      "$HOME/.omp/wt/stale" "$HOME/.omp/wt/malformed" "$HOME/.cache/oh-my-pi" \
      "$XDG_STATE_HOME/atyrode/omp-untrusted" "$XDG_STATE_HOME/atyrode/omp-plain-seed"
    printf '{"session":"one"}\n' > "$HOME/.omp/agent/sessions/project/one.jsonl"
    printf '{"session":"two"}\n' > "$HOME/.omp/agent/sessions/project/two.jsonl"
    printf 'dirty worktree payload\n' > "$HOME/.omp/wt/dirty/fixture"
    printf 'clean stale payload\n' > "$HOME/.omp/wt/stale/fixture"
    printf 'checked-out branch payload\n' > "$HOME/.omp/wt/branch-live/fixture"
    printf 'active worktree payload\n' > "$HOME/.omp/wt/marker-live/fixture"
    touch "$HOME/.omp/wt/marker-live/.active"
    printf 'cache' > "$HOME/.cache/oh-my-pi/cache"
    printf 'state' > "$XDG_STATE_HOME/atyrode/omp-untrusted/session"
    printf 'seed' > "$XDG_STATE_HOME/atyrode/omp-plain-seed/seed"
    mkdir -p "$TMPDIR/lifecycle-generation"
    printf 'not-a-store-closure' > "$TMPDIR/lifecycle-generation/payload"
    ln -s "$TMPDIR/lifecycle-generation" "$XDG_STATE_HOME/nix/profiles/home-manager-3-link"
    test -L "$XDG_STATE_HOME/nix/profiles/home-manager-3-link"
    snapshot_lifecycle_state() {
      local root
      for root in "$HOME/.omp" "$HOME/.cache/oh-my-pi" "$XDG_STATE_HOME/atyrode"; do
        printf 'root\t%s\n' "$root"
        find "$root" -printf '%y\t%P\t%l\n' | LC_ALL=C sort
        find "$root" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
      done
    }
    snapshot_lifecycle_state > "$TMPDIR/lifecycle-state.before"
    rm -f "$TMPDIR/omp-args"
    export ATYRODE_LIFECYCLE_REPO="$TMPDIR/lifecycle-repo"
    lifecycle_one="$(atyrode lifecycle --json)"
    lifecycle_two="$(atyrode lifecycle --json)"
    test "$lifecycle_one" = "$lifecycle_two" \
      || { echo 'lifecycle JSON must be byte-stable for one fixture state' >&2; exit 1; }
    jq -e '.schemaVersion == 1' <<<"$lifecycle_one" >/dev/null
    jq -e '[.entries[] | select(.category == "home-manager-generation" and .classification == "protected-current")] | length == 1' <<<"$lifecycle_one" >/dev/null
    jq -e --arg path "$XDG_STATE_HOME/nix/profiles/home-manager-3-link" '[.entries[] | select(.path == $path and .classification == "protected-current" and .bytes == null)] | length == 1' <<<"$lifecycle_one" >/dev/null \
      || { echo 'lifecycle must not report symlink bytes as a Home Manager closure size' >&2; exit 1; }
    jq -e --arg path "$TMPDIR/lifecycle-repo" '[.entries[] | select(.path == $path and .classification == "active")] | length == 1' <<<"$lifecycle_one" >/dev/null
    jq -e --arg path "$HOME/.omp/wt/dirty" '[.entries[] | select(.category == "omp-worktree" and .path == $path and .classification == "dirty")] | length == 1' <<<"$lifecycle_one" >/dev/null
    jq -e --arg path "$HOME/.omp/wt/malformed" '[.entries[] | select(.path == $path and .classification == "unknown" and .state == "malformed")] | length == 1' <<<"$lifecycle_one" >/dev/null
    jq -e '[.entries[] | select(.category == "omp-cache" and .classification == "disposable")] | length == 1' <<<"$lifecycle_one" >/dev/null
    jq -e '[.diagnostics[] | select(.code == "malformed")] | length >= 1' <<<"$lifecycle_one" >/dev/null \
      || { echo "lifecycle JSON classification is wrong: $lifecycle_one" >&2; exit 1; }
    jq -e --arg root "$HOME/.omp" --arg sessions "$HOME/.omp/agent/sessions" \
      '.omp.stateRoot.path == $root and (.omp.stateRoot.bytes | type) == "number"
        and .omp.sessions.path == $sessions and .omp.sessions.count == 2
        and (.omp.sessions.bytes | type) == "number"' <<<"$lifecycle_one" >/dev/null \
      || { echo "lifecycle OMP state/session summary is wrong: $lifecycle_one" >&2; exit 1; }
    jq -e --arg cache "$HOME/.cache/oh-my-pi" \
      '[.omp.caches[] | select(.path == $cache and (.bytes | type) == "number" and .state == "present")] | length == 1' \
      <<<"$lifecycle_one" >/dev/null \
      || { echo "lifecycle OMP cache summary is wrong: $lifecycle_one" >&2; exit 1; }
    jq -e '.omp.dryRuns.available
      and .omp.dryRuns.gc.command == ["omp","gc"] and .omp.dryRuns.gc.dryRun
      and .omp.dryRuns.gc.status == "ok" and (.omp.dryRuns.gc.output | contains("GC dry-run"))
      and .omp.dryRuns.worktreeClear.command == ["omp","worktree","clear","--dry-run"]
      and .omp.dryRuns.worktreeClear.dryRun and .omp.dryRuns.worktreeClear.status == "ok"
      and (.omp.dryRuns.worktreeClear.output | contains("would remove"))' \
      <<<"$lifecycle_one" >/dev/null \
      || { echo "lifecycle must capture only supported OMP dry-runs: $lifecycle_one" >&2; exit 1; }

    test_lifecycle_omp_live_worktree_protection() {
      jq -e --arg path "$HOME/.omp/wt/dirty" \
        '[.omp.worktrees[] | select(.path == $path and .classification == "live" and .protected
          and .state == "dirty" and ([.signals[].kind] | index("dirty-git-tree")))] | length == 1' \
        <<<"$lifecycle_one" >/dev/null \
        || { echo "dirty OMP worktree must be live and protected: $lifecycle_one" >&2; exit 1; }
      jq -e --arg path "$HOME/.omp/wt/stale" \
        '[.omp.worktrees[] | select(.path == $path and .classification == "reclaimable"
          and (.protected | not) and .state == "clean")] | length == 1' \
        <<<"$lifecycle_one" >/dev/null \
        || { echo "clean stale OMP worktree must be reclaimable: $lifecycle_one" >&2; exit 1; }
      jq -e --arg path "$HOME/.omp/wt/branch-live" \
        '[.omp.worktrees[] | select(.path == $path and .classification == "live" and .protected
          and .branch == "omp/live" and ([.signals[].kind] | index("checked-out-branch")))] | length == 1' \
        <<<"$lifecycle_one" >/dev/null \
        || { echo "checked-out OMP branch must be live and protected: $lifecycle_one" >&2; exit 1; }
      jq -e --arg path "$HOME/.omp/wt/marker-live" \
        '[.omp.worktrees[] | select(.path == $path and .classification == "live" and .protected
          and ([.signals[].kind] | index("activity-marker")))] | length == 1' \
        <<<"$lifecycle_one" >/dev/null \
        || { echo "OMP activity marker must protect its worktree: $lifecycle_one" >&2; exit 1; }
    }
    test_lifecycle_omp_live_worktree_protection
    lifecycle_human="$(atyrode lifecycle 2>&1)"
    grep -qF 'lifecycle inventory (read-only)' <<<"$lifecycle_human" \
      || { echo "lifecycle human output lacks a useful heading: $lifecycle_human" >&2; exit 1; }
    grep -qF 'dirty' <<<"$lifecycle_human" \
      || { echo "lifecycle human output must expose dirty worktrees: $lifecycle_human" >&2; exit 1; }
    grep -qF 'GC dry-run: 2 stale sessions, 4096 bytes reclaimable' <<<"$lifecycle_human" \
      || { echo "lifecycle human output must include omp gc dry-run output: $lifecycle_human" >&2; exit 1; }
    grep -qF "would remove $HOME/.omp/wt/stale" <<<"$lifecycle_human" \
      || { echo "lifecycle human output must include omp worktree clear dry-run output: $lifecycle_human" >&2; exit 1; }
    lifecycle_unavailable="$(ATYRODE_NIX_ENV="$TMPDIR/bin/missing-nix-env" atyrode lifecycle --json)"
    jq -e '[.diagnostics[] | select(.code == "tool-unavailable" and .scope == "generations")] | length == 1' \
      <<<"$lifecycle_unavailable" >/dev/null \
      || { echo "lifecycle must report unavailable tools structurally: $lifecycle_unavailable" >&2; exit 1; }
    set +e
    lifecycle_omp_absent="$(ATYRODE_OMP="$TMPDIR/bin/missing-omp" atyrode lifecycle --json)"
    lifecycle_omp_absent_status="$?"
    set -e
    test "$lifecycle_omp_absent_status" = 0 \
      || { echo "lifecycle must succeed without omp (exit $lifecycle_omp_absent_status)" >&2; exit 1; }
    jq -e '.omp.dryRuns.available == false
      and .omp.dryRuns.gc.status == "unavailable" and .omp.dryRuns.gc.output == null
      and .omp.dryRuns.worktreeClear.status == "unavailable"
      and (.omp.worktrees | length) == 5' <<<"$lifecycle_omp_absent" >/dev/null \
      || { echo "missing omp must retain the filesystem-only report: $lifecycle_omp_absent" >&2; exit 1; }
    unexpected_omp_args="$(grep -Ev '^(gc|worktree clear --dry-run)$' "$TMPDIR/omp-args" || true)"
    test -z "$unexpected_omp_args" \
      || { echo "lifecycle invoked an unsafe/unsupported omp command: $unexpected_omp_args" >&2; exit 1; }
    grep -qxF 'gc' "$TMPDIR/omp-args"
    grep -qxF 'worktree clear --dry-run' "$TMPDIR/omp-args"
    snapshot_lifecycle_state > "$TMPDIR/lifecycle-state.after"
    test_lifecycle_omp_report_no_mutation() {
      cmp "$TMPDIR/lifecycle-state.before" "$TMPDIR/lifecycle-state.after" \
        || { echo 'lifecycle OMP report changed the fabricated state tree' >&2; exit 1; }
    }
    test_lifecycle_omp_report_no_mutation
    grep -qx 'cache' "$HOME/.cache/oh-my-pi/cache" \
      || { echo 'lifecycle must not mutate the fixture cache' >&2; exit 1; }
    grep -qx 'state' "$XDG_STATE_HOME/atyrode/omp-untrusted/session" \
      || { echo 'lifecycle must not mutate the fixture state' >&2; exit 1; }
    unset ATYRODE_LIFECYCLE_REPO

    # Colour is opt-in on the outcome: forced on it wraps the footer in SGR codes,
    # and by default (no tty, no override) the output stays byte-plain so pipes and
    # this harness read clean text. \033 is the ESC that opens every SGR sequence.
    color_out="$(ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc" ATYRODE_NH_NOISE=1 _ATYRODE_TEST_COLOR=1 \
      atyrode clean --keep 3 --yes 2>&1)"
    printf '%s' "$color_out" | grep -q "$(printf '\033')" \
      || { echo 'forced colour must emit ANSI SGR codes' >&2; exit 1; }
    plain_out="$(ATYRODE_NIX_STORE="$TMPDIR/bin/fake-gc" ATYRODE_NH_NOISE=1 \
      atyrode clean --keep 3 --yes 2>&1)"
    printf '%s' "$plain_out" | grep -q "$(printf '\033')" \
      && { echo 'default (non-tty) output must stay plain — no ANSI codes' >&2; exit 1; }
    rm -f "$TMPDIR/gc-args"

    # Inventory is a stable JSON-only surface. The test hook substitutes an
    # evaluated fixture without teaching production builds to trust environment
    # data or requiring network access in the derivation sandbox.
    cat > "$TMPDIR/inventory.json" <<'EOF'
    {
      "schemaVersion": 1,
      "identity": {"revision":"0123456789abcdef","system":"x86_64-linux","platform":"linux"},
      "authority": {"membership":"evaluated configurations","intent":"annotations","closureIncluded":false,"mutableStateIncluded":false},
      "capabilities": {"base":{"name":"base","deliverables":[]}},
      "hosts": {
        "fixture-host": {
          "id":"fixture-host",
          "description":"fixture",
          "homeDirectory":"/home/alex",
          "hostname":null,
          "platform":"linux",
          "system":"x86_64-linux",
          "username":"alex",
          "capabilities":["base"],
          "deliverables":[]
        }
      },
      "boundaries": {}
    }
    EOF
    export _ATYRODE_TEST_INVENTORY="$TMPDIR/inventory.json"
    inventory_one="$(atyrode inventory --repo "$HOME/nix-dotfiles" --json)"
    inventory_two="$(atyrode inventory --repo "$HOME/nix-dotfiles" --json)"
    test "$inventory_one" = "$inventory_two" \
      || { echo 'inventory JSON must be byte-stable for one evaluated manifest' >&2; exit 1; }
    jq -e '.schemaVersion == 1 and .identity.revision == "0123456789abcdef"' \
      <<<"$inventory_one" >/dev/null
    host_inventory="$(atyrode inventory --repo "$HOME/nix-dotfiles" --host fixture-host --json)"
    jq -e '.schemaVersion == 1 and .identity.system == "x86_64-linux"
      and .host.id == "fixture-host" and .host.capabilities == ["base"]' \
      <<<"$host_inventory" >/dev/null
    if atyrode inventory --repo "$HOME/nix-dotfiles" --host absent --json >/dev/null 2>&1; then
      echo 'inventory must reject hosts absent from the evaluated revision' >&2
      exit 1
    fi
    if atyrode inventory --repo "$HOME/nix-dotfiles" >/dev/null 2>&1; then
      echo 'inventory must require the explicit JSON contract' >&2
      exit 1
    fi
    help="$(atyrode --help)"
    grep -qF 'then prints preflight metadata without invoking nh; --dry-run invokes the normal' <<<"$help"
    grep -qF 'nh switch backend with --dry; --preview-json runs that dry backend and emits its' <<<"$help"
    grep -qF 'atyrode capabilities list [--json]' <<<"$help"
    grep -qF 'atyrode capabilities show [HOST] [--json]' <<<"$help"
    unset _ATYRODE_TEST_INVENTORY

    mkdir "$out"
  ''
