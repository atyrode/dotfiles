{ atyrode, pkgs }:

let
  fixtures = import ./lib/atyrode-fixtures.nix { inherit pkgs; };
in
pkgs.runCommand "check-atyrode-credentials"
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
    cat > "$TMPDIR/bin/bw" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/bw-args"
    case "$*" in
      status)
        # ATYRODE_TEST_BW_STATE_FILE makes the stub stateful: once `login` has
        # run (the file exists), status flips to unlocked — exercising the
        # login-then-proceed path of onboarding commands.
        if [[ -n "''${ATYRODE_TEST_BW_STATE_FILE:-}" && -f "''${ATYRODE_TEST_BW_STATE_FILE:-}" ]]; then
          printf '{"status":"unlocked"}\n'
        else
          printf '{"status":"%s"}\n' "''${ATYRODE_TEST_BW_STATUS:-unlocked}"
        fi
        ;;
      login)
        [[ -z "''${ATYRODE_TEST_BW_STATE_FILE:-}" ]] || touch "$ATYRODE_TEST_BW_STATE_FILE"
        ;;
      sync|lock) ;;
      'config server') printf '%s\n' 'https://vault.bitwarden.com' ;;
      'config server '*) ;;
      'list items --search vault-existing')
        printf '%s\n' '[{"id":"vault-existing-id","name":"vault-existing","type":2}]'
        ;;
      'list items --search vault-login')
        printf '%s\n' '[{"id":"vault-login-id","name":"vault-login","type":1}]'
        ;;
      'list items --search vault-duplicate')
        printf '%s\n' \
          '[{"id":"duplicate-1","name":"vault-duplicate","type":2},{"id":"duplicate-2","name":"vault-duplicate","type":2}]'
        ;;
      'list items --search Agent session archive')
        printf '%s\n' '[{"id":"backup-note-id","name":"Agent session archive","type":2}]'
        ;;
      'list items --search '*) printf '%s\n' '[]' ;;
      'get template item')
        printf '%s\n' '{"type":2,"name":"","notes":null,"secureNote":{"type":0}}'
        ;;
      'get item vault-existing-id')
        printf '%s\n' '{"id":"vault-existing-id","name":"vault-existing","type":2,"notes":"VAULT-OLD-SECRET","secureNote":{"type":0}}'
        ;;
      'get item backup-note-id')
        if [[ "''${ATYRODE_TEST_BACKUP_NOTE:-full}" == incomplete ]]; then
          printf '%s\n' '{"id":"backup-note-id","type":2,"notes":"{\"endpoint\":\"cellar.test.example\",\"bucket\":\"test-bucket\",\"keyId\":\"TESTKEYID\",\"cryptPassword\":\"TEST-CRYPT-PW\",\"cryptSalt\":\"TEST-CRYPT-SALT\"}"}'
        else
          printf '%s\n' '{"id":"backup-note-id","type":2,"notes":"{\"endpoint\":\"cellar.test.example\",\"bucket\":\"test-bucket\",\"keyId\":\"TESTKEYID\",\"keySecret\":\"TEST-S3-SECRET\",\"cryptPassword\":\"TEST-CRYPT-PW\",\"cryptSalt\":\"TEST-CRYPT-SALT\"}"}'
        fi
        ;;
      'get item '*)
        printf '%s\n' '{"id":"f0b39ebf-62ae-4198-808b-b4b200002e8c","name":"Tyrode Clan operator age identity","notes":"# created: 2026-08-25T00:00:00Z\n# public key: age1test\nAGE-SECRET-KEY-1TESTONLY"}'
        ;;
      encode)
        tee "$TMPDIR/bw-encoded-input" >/dev/null
        printf '%s\n' 'ENCODED'
        ;;
      'create item'|'edit item '*)
        test "$(cat)" = ENCODED
        printf '%s\n' '{"notes":"VAULT-WRITE-RESPONSE-MUST-NOT-PRINT"}'
        ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/rclone" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/rclone-args"
    case "''${1:-}" in
      obscure)
        # Plaintext must arrive on stdin, never as an argument.
        [[ "''${2:-}" == - ]] || exit 64
        printf 'OBSCURED-%s\n' "$(cat)"
        ;;
      lsd)
        # Proves the env file was sourced into the probe's environment.
        [[ -n "''${RCLONE_CONFIG_CELLAR_ENDPOINT:-}" ]] || exit 64
        [[ "''${ATYRODE_TEST_RCLONE_LSD_FAIL:-0}" != 1 ]]
        ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/age-keygen" <<'EOF'
    #!${pkgs.runtimeShell}
    [[ "''${1:-}" == -y ]] || exit 64
    printf '%s\n' 'age1pjcf90jv97whw39dxtynv99rwgdj4u7nuy7m3a4fvhgfrsrgvsespknzgm'
    EOF
    cat > "$TMPDIR/bin/infra-nix" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/infra-nix-args"
    case "''${1:-}" in
      develop) exit 0 ;;
      eval) printf '%s\n' '/nix/store/test-tyrode-dev-01-system.drv' ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/infra-ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/infra-ssh-args"
    if [[ "$*" == *'atyrode doctor host --json'* ]]; then
      printf '%s\n' '{"ok":true,"host":"tyrode-dev-01","registered":{"activation":"nixos"}}'
    fi
    EOF
    chmod +x "$TMPDIR/bin/bw" "$TMPDIR/bin/rclone" "$TMPDIR/bin/age-keygen" "$TMPDIR/bin/infra-nix" "$TMPDIR/bin/infra-ssh"
    mkdir -p "$TMPDIR/infra/.git" "$TMPDIR/infra/inventory" \
      "$TMPDIR/infra/machines/tyrode-dev-01"
    touch "$TMPDIR/infra/flake.nix"
    cat > "$TMPDIR/infra/clan.nix" <<'EOF'
    {
      vars.settings.secretStore = "age";
    }
    EOF
    cat > "$TMPDIR/infra/inventory/vps-enrollment.json" <<'EOF'
    {
      "machines": {"tyrode-dev-01": {"role": "personal-development"}},
      "roles": {"personal-development": {"profile": "alex"}},
      "profiles": {"alex": {"username": "alex"}}
    }
    EOF
    cat > "$TMPDIR/infra/machines/tyrode-dev-01/network-intent.json" <<'EOF'
    {
      "uplinks": [
        {"addresses": [{"family": "ipv4", "value": "target.example"}]}
      ]
    }
    EOF
    export PATH="$TMPDIR/bin:$PATH"
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
    vault_test_env=(env ATYRODE_BW="$TMPDIR/bin/bw")
    vault_status="$("''${vault_test_env[@]}" atyrode vault status --json)"
    jq -e '.status == "unlocked"' <<<"$vault_status" >/dev/null
    vault_get="$("''${vault_test_env[@]}" atyrode vault get vault-existing)"
    test "$vault_get" = VAULT-OLD-SECRET

    printf '%s' VAULT-NEW-SECRET |
      "''${vault_test_env[@]}" atyrode vault put vault-new \
        >"$TMPDIR/vault-put-out" 2>"$TMPDIR/vault-put-err"
    test ! -s "$TMPDIR/vault-put-out"
    grep -qF 'created Bitwarden Secure Note vault-new' "$TMPDIR/vault-put-err"
    jq -e '.name == "vault-new" and .type == 2 and .secureNote.type == 0
      and .notes == "VAULT-NEW-SECRET"' "$TMPDIR/bw-encoded-input" >/dev/null
    ! grep -qF 'VAULT-NEW-SECRET' "$TMPDIR/bw-args"
    ! grep -qF 'VAULT-WRITE-RESPONSE-MUST-NOT-PRINT' \
      "$TMPDIR/vault-put-out" "$TMPDIR/vault-put-err"

    printf '%s' VAULT-UPDATED-SECRET |
      "''${vault_test_env[@]}" atyrode vault put vault-existing \
        >"$TMPDIR/vault-edit-out" 2>"$TMPDIR/vault-edit-err"
    test ! -s "$TMPDIR/vault-edit-out"
    grep -qF 'updated Bitwarden Secure Note vault-existing' "$TMPDIR/vault-edit-err"
    jq -e '.id == "vault-existing-id" and .notes == "VAULT-UPDATED-SECRET"' \
      "$TMPDIR/bw-encoded-input" >/dev/null
    grep -qF 'edit item vault-existing-id' "$TMPDIR/bw-args"

    if "''${vault_test_env[@]}" atyrode vault get vault-missing >/dev/null 2>&1; then
      echo 'vault get must reject a missing Secure Note' >&2
      exit 1
    fi
    if "''${vault_test_env[@]}" atyrode vault get vault-login >/dev/null 2>&1; then
      echo 'vault get must reject a non-note item' >&2
      exit 1
    fi
    if "''${vault_test_env[@]}" atyrode vault get vault-duplicate >/dev/null 2>&1; then
      echo 'vault get must reject duplicate exact names' >&2
      exit 1
    fi
    ! grep -qxF lock "$TMPDIR/bw-args"

    # A first login on a fresh machine must pin the operator's EU server
    # before authenticating: bw defaults to vault.bitwarden.com and then
    # rejects the correct master password with a misleading error.
    "''${vault_test_env[@]}" ATYRODE_TEST_BW_STATUS=unauthenticated _ATYRODE_TEST_TTY=1 \
      atyrode vault login >/dev/null
    grep -qxF 'config server https://vault.bitwarden.eu' "$TMPDIR/bw-args"
    grep -qxF login "$TMPDIR/bw-args"

    backup_test_env=(env ATYRODE_BW="$TMPDIR/bin/bw" ATYRODE_RCLONE="$TMPDIR/bin/rclone")

    backup_status="$("''${backup_test_env[@]}" atyrode backup status --json)"
    jq -e '.configured == false and .lastSuccess == null
      and .ageHours == null and .remoteReachable == null' <<<"$backup_status" >/dev/null

    set +e
    "''${backup_test_env[@]}" atyrode backup now >/dev/null 2>"$TMPDIR/backup-now.err"
    backup_now_status=$?
    set -e
    test "$backup_now_status" = 69
    grep -qF 'atyrode apply' "$TMPDIR/backup-now.err"

    if "''${backup_test_env[@]}" ATYRODE_TEST_BACKUP_NOTE=incomplete \
      atyrode backup setup >/dev/null 2>"$TMPDIR/backup-bad.err"; then
      echo 'backup setup must reject a vault note with a missing field' >&2
      exit 1
    fi
    grep -qF "missing or has an empty 'keySecret' field" "$TMPDIR/backup-bad.err"
    test ! -e "$XDG_CONFIG_HOME/atyrode/session-backup/env"

    rm -f "$TMPDIR/rclone-args"
    "''${backup_test_env[@]}" atyrode backup setup \
      >"$TMPDIR/backup-setup.out" 2>"$TMPDIR/backup-setup.err"
    test ! -s "$TMPDIR/backup-setup.out"
    grep -qF 'atyrode backup now' "$TMPDIR/backup-setup.err"
    backup_env_file="$XDG_CONFIG_HOME/atyrode/session-backup/env"
    test -f "$backup_env_file"
    test "$(stat -c %a "$backup_env_file")" = 600
    test "$(stat -c %a "$XDG_CONFIG_HOME/atyrode/session-backup")" = 700
    grep -qxF 'RCLONE_CONFIG_CELLAR_ENDPOINT=cellar.test.example' "$backup_env_file"
    grep -qxF 'RCLONE_CONFIG_ARCHIVE_REMOTE=cellar:test-bucket' "$backup_env_file"
    grep -qxF 'RCLONE_CONFIG_ARCHIVE_PASSWORD=OBSCURED-TEST-CRYPT-PW' "$backup_env_file"
    grep -qxF 'RCLONE_CONFIG_ARCHIVE_PASSWORD2=OBSCURED-TEST-CRYPT-SALT' "$backup_env_file"
    # The crypt secrets reach rclone via stdin only, and no secret reaches an
    # argv, stdout, or stderr.
    ! grep -qF 'TEST-CRYPT-PW' "$TMPDIR/rclone-args"
    ! grep -qF 'TEST-CRYPT-SALT' "$TMPDIR/rclone-args"
    ! grep -qF 'TEST-S3-SECRET' "$TMPDIR/rclone-args" "$TMPDIR/bw-args" \
      "$TMPDIR/backup-setup.out" "$TMPDIR/backup-setup.err"
    ! grep -qF 'TEST-CRYPT-PW' "$TMPDIR/backup-setup.out" "$TMPDIR/backup-setup.err"

    mkdir -p "$XDG_STATE_HOME/atyrode/session-backup"
    date -u +%FT%TZ >"$XDG_STATE_HOME/atyrode/session-backup/last-success"
    backup_status="$("''${backup_test_env[@]}" atyrode backup status --json)"
    jq -e '.configured == true and .remoteReachable == true and .ageHours == 0
      and (.lastSuccess | type == "string")' <<<"$backup_status" >/dev/null
    grep -qF 'lsd archive: --contimeout 10s --timeout 20s' "$TMPDIR/rclone-args"

    backup_status="$("''${backup_test_env[@]}" ATYRODE_TEST_RCLONE_LSD_FAIL=1 \
      atyrode backup status --json)"
    jq -e '.configured == true and .remoteReachable == false' <<<"$backup_status" >/dev/null

    # A fresh machine (never logged in) must be able to onboard through
    # `backup setup` alone: pin the EU server, log in, unlock, render the env
    # file — no separate `vault login` step required.
    rm -f "$XDG_CONFIG_HOME/atyrode/session-backup/env" "$TMPDIR/bw-args"
    "''${backup_test_env[@]}" ATYRODE_TEST_BW_STATUS=unauthenticated \
      ATYRODE_TEST_BW_STATE_FILE="$TMPDIR/bw-logged-in" _ATYRODE_TEST_TTY=1 \
      atyrode backup setup >/dev/null 2>"$TMPDIR/backup-fresh.err"
    grep -qxF 'config server https://vault.bitwarden.eu' "$TMPDIR/bw-args"
    grep -qxF login "$TMPDIR/bw-args"
    test -f "$XDG_CONFIG_HOME/atyrode/session-backup/env"
    test "$(stat -c %a "$XDG_CONFIG_HOME/atyrode/session-backup/env")" = 600
    rm -f "$TMPDIR/bw-logged-in"

    infra_test_env=(
      env
      ATYRODE_AGE_KEYGEN="$TMPDIR/bin/age-keygen"
      ATYRODE_BW="$TMPDIR/bin/bw"
      ATYRODE_NIX="$TMPDIR/bin/infra-nix"
      ATYRODE_SSH="$TMPDIR/bin/infra-ssh"
    )
    infra_setup="$("''${infra_test_env[@]}" atyrode infra setup --repo "$TMPDIR/infra" --json)"
    jq -e '.ok and .action == "setup" and .machine == "tyrode-dev-01"
      and .sourceChanged and .privateMaterialPrinted == false' <<<"$infra_setup" >/dev/null
    grep -qF 'clan vars fix tyrode-dev-01' "$TMPDIR/infra-nix-args"
    grep -qF 'clan vars check tyrode-dev-01' "$TMPDIR/infra-nix-args"
    ! grep -qF 'AGE-SECRET-KEY-1TESTONLY' <<<"$infra_setup"
    grep -qF 'vars.settings.recipients.hosts.tyrode-dev-01' "$TMPDIR/infra/clan.nix"
    grep -qF 'age1pjcf90jv97whw39dxtynv99rwgdj4u7nuy7m3a4fvhgfrsrgvsespknzgm' \
      "$TMPDIR/infra/clan.nix"
    infra_setup_again="$("''${infra_test_env[@]}" atyrode infra setup --repo "$TMPDIR/infra" --json)"
    jq -e '.ok and .action == "setup" and (.sourceChanged | not)' <<<"$infra_setup_again" >/dev/null
    test "$(grep -Fc 'vars.settings.recipients.hosts.tyrode-dev-01' "$TMPDIR/infra/clan.nix")" = 1

    infra_plan="$("''${infra_test_env[@]}" atyrode infra plan --repo "$TMPDIR/infra" --json)"
    jq -e '.ok and .action == "plan" and .machine == "tyrode-dev-01"
      and .targetHost == "alex@target.example" and .hostKeyCheck == "strict"
      and .buildHost == "localhost"
      and .drvPath == "/nix/store/test-tyrode-dev-01-system.drv"
      and .privateMaterialPrinted == false' <<<"$infra_plan" >/dev/null
    grep -qF 'BatchMode=yes -o StrictHostKeyChecking=yes' "$TMPDIR/infra-ssh-args"
    grep -qF 'alex@target.example true' "$TMPDIR/infra-ssh-args"
    ! grep -qF 'AGE-SECRET-KEY-1TESTONLY' <<<"$infra_plan"

    for checkout_state in dirty feature divergent; do
      case "$checkout_state" in
        dirty) expected_error='infra checkout is dirty' ;;
        feature) expected_error='infra apply requires the main branch' ;;
        divergent) expected_error='infra checkout has local commits or diverged from origin/main' ;;
      esac
      if "''${infra_test_env[@]}" ATYRODE_TEST_INFRA_GIT_STATE="$checkout_state" \
        atyrode infra apply --repo "$TMPDIR/infra" --yes --json \
        >"$TMPDIR/infra-$checkout_state.out" 2>"$TMPDIR/infra-$checkout_state.err"; then
        echo "infra apply must reject a $checkout_state checkout" >&2
        exit 1
      fi
      grep -qF "$expected_error" "$TMPDIR/infra-$checkout_state.err"
    done

    if "''${infra_test_env[@]}" ATYRODE_TEST_BW_STATUS=unauthenticated \
      atyrode infra apply --repo "$TMPDIR/infra" --yes --json \
      >"$TMPDIR/infra-unauthenticated.out" 2>"$TMPDIR/infra-unauthenticated.err"; then
      echo "infra apply must reject an unauthenticated vault" >&2
      exit 1
    fi
    grep -qF '0123456789ab -> 0123456789ab' "$TMPDIR/infra-unauthenticated.err"
    grep -qF 'infra checkout already matches origin/main' "$TMPDIR/infra-unauthenticated.err"
    grep -qF "Bitwarden is not logged in; run 'atyrode vault login'" \
      "$TMPDIR/infra-unauthenticated.err"

    rm -f "$TMPDIR/infra-fast-forwarded"
    printf 'y\n' |
      "''${infra_test_env[@]}" _ATYRODE_TEST_TTY=1 ATYRODE_TEST_INFRA_GIT_STATE=behind \
        atyrode infra apply --repo "$TMPDIR/infra" --json \
        >"$TMPDIR/infra-behind.out" 2>"$TMPDIR/infra-behind.err"
    test -e "$TMPDIR/infra-fast-forwarded"
    jq -e '.ok and .action == "apply" and .machine == "tyrode-dev-01"
      and .targetHost == "alex@target.example" and .verified' \
      "$TMPDIR/infra-behind.out" >/dev/null
    grep -qF '0123456789ab -> feedfacefeed' "$TMPDIR/infra-behind.err"
    grep -qF 'feedface pin: update reviewed dotfiles' "$TMPDIR/infra-behind.err"
    grep -qF 'decafbad fix: retain manifold ingress' "$TMPDIR/infra-behind.err"
    grep -qF 'deploy tyrode-dev-01 to alex@target.example from feedfacefeed now?' \
      "$TMPDIR/infra-behind.err"

    infra_apply="$("''${infra_test_env[@]}" \
      atyrode infra apply --repo "$TMPDIR/infra" --yes --json \
      2>"$TMPDIR/infra-current.err")"
    jq -e '.ok and .action == "apply" and .machine == "tyrode-dev-01"
      and .targetHost == "alex@target.example" and .verified
      and .privateMaterialPrinted == false' <<<"$infra_apply" >/dev/null
    grep -qF '0123456789ab -> 0123456789ab' "$TMPDIR/infra-current.err"
    grep -qF 'infra checkout already matches origin/main' "$TMPDIR/infra-current.err"
    grep -qF 'clan machines update tyrode-dev-01' "$TMPDIR/infra-nix-args"
    grep -qF -- '--target-host alex@target.example --build-host localhost --upload-inputs --host-key-check strict' \
      "$TMPDIR/infra-nix-args"
    grep -qF 'alex@target.example atyrode doctor host --json' "$TMPDIR/infra-ssh-args"
    ! grep -qF 'AGE-SECRET-KEY-1TESTONLY' <<<"$infra_apply"

    # --- provision git (#8): vault-backed per-machine key custody -------------
    # A stateful vault stub emulates Bitwarden storage, a REAL ssh-agent and
    # ssh-keygen exercise the custody mechanics: generate on one home, recover
    # on a second home from the vault alone, and prove the two homes hold the
    # same identities while no private key ever lands on disk (memory default).
    export VAULT_STORE="$TMPDIR/vault-store"
    mkdir -p "$VAULT_STORE"
    cat > "$TMPDIR/bin/vault-bw" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    note_id() { printf 'note-%s\n' "$(printf '%s' "$1" | base64 -w0 | tr '+/=' '._-')"; }
    case "$*" in
      status) printf '{"status":"unlocked"}\n' ;;
      sync|lock) ;;
      'list items --search '*)
        all="$*"
        name="''${all#list items --search }"
        id="$(note_id "$name")"
        if [[ -f "$VAULT_STORE/$id" ]]; then
          jq -nc --arg id "$id" --arg name "$name" '[{id:$id,name:$name,type:2}]'
        else
          printf '[]\n'
        fi
        ;;
      'get template item')
        printf '%s\n' '{"type":2,"name":"","notes":null,"secureNote":{"type":0}}'
        ;;
      'get item note-'*)
        id="$3"
        [[ -f "$VAULT_STORE/$id" ]] || exit 64
        jq -nc --arg id "$id" --rawfile notes "$VAULT_STORE/$id" \
          '{id:$id,type:2,secureNote:{type:0},notes:$notes}'
        ;;
      encode)
        tee "$VAULT_STORE/.encode-last" >/dev/null
        printf 'ENCODED\n'
        ;;
      'create item')
        test "$(cat)" = ENCODED
        name="$(jq -r '.name' "$VAULT_STORE/.encode-last")"
        jq -rj '.notes' "$VAULT_STORE/.encode-last" > "$VAULT_STORE/$(note_id "$name")"
        printf '{}\n'
        ;;
      'edit item '*)
        test "$(cat)" = ENCODED
        name="$(jq -r '.name' "$VAULT_STORE/.encode-last")"
        jq -rj '.notes' "$VAULT_STORE/.encode-last" > "$VAULT_STORE/$(note_id "$name")"
        printf '{}\n'
        ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/gh-stub" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/gh-args"
    EOF
    chmod +x "$TMPDIR/bin/vault-bw" "$TMPDIR/bin/gh-stub"

    cat > "$TMPDIR/bin/auth-systemctl" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      '--user cat atyrode-omp-auth-brokers.service') exit 0 ;;
      '--user restart atyrode-omp-auth-brokers.service')
        touch "$TMPDIR/auth-broker-restarted"
        ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/auth-curl" <<'EOF'
    #!${pkgs.runtimeShell}
    set -eu
    printf '%s\n' "$*" > "$TMPDIR/auth-curl-args"
    cfg="" payload="" output="" url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --config) shift; cfg="$1" ;;
        --data-binary) shift; payload="''${1#@}" ;;
        -o) shift; output="$1" ;;
        http://*) url="$1" ;;
      esac
      shift
    done
    grep -Fx 'header = "Authorization: Bearer BROKER-TOKEN-TEST"' "$cfg" >/dev/null
    test "$url" = 'http://127.0.0.1:46171/v1/credential'
    jq -e '.provider == "deepseek"
      and .credential.type == "api_key"
      and .credential.key == "sk-deepseek-test"' "$payload" >/dev/null
    printf '{"entries":[{"provider":"deepseek","credential":{"type":"api_key","key":"redacted-in-test-response"}}]}\n' > "$output"
    EOF
    chmod +x "$TMPDIR/bin/auth-systemctl" "$TMPDIR/bin/auth-curl"

    eval "$(${pkgs.openssh}/bin/ssh-agent -s)" >/dev/null
    provision_env=(env ATYRODE_BW="$TMPDIR/bin/vault-bw" ATYRODE_GH="$TMPDIR/bin/gh-stub" \
      _ATYRODE_TEST_HOSTNAME=fixture-host)

    # No agent socket → fail closed, never downgrade.
    if "''${provision_env[@]}" SSH_AUTH_SOCK= atyrode provision git --yes >/dev/null 2>&1; then
      echo 'provision git unexpectedly ran without an ssh-agent' >&2
      exit 1
    fi

    # Fresh machine: generate both identities, vault first, agent memory only.
    "''${provision_env[@]}" atyrode provision git --yes 2> "$TMPDIR/provision-fresh.err"
    test -f "$HOME/.ssh/id_ed25519.pub"
    test -f "$HOME/.ssh/id_ed25519_git_signing.pub"
    test ! -e "$HOME/.ssh/id_ed25519"
    test ! -e "$HOME/.ssh/id_ed25519_git_signing"
    test "$(${pkgs.openssh}/bin/ssh-add -l | wc -l)" = 2
    test -f "$VAULT_STORE/$(printf 'note-%s' "$(printf '%s' 'Git SSH auth key (fixture-host)' | base64 -w0 | tr '+/=' '._-')")"
    grep -qF -- 'ssh-key add' "$TMPDIR/gh-args"
    grep -qF -- '--type signing' "$TMPDIR/gh-args"
    grep -qF 'not yet in home/git-allowed-signers' "$TMPDIR/provision-fresh.err"
    auth_fingerprint="$(${pkgs.openssh}/bin/ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" | awk '{print $2}')"
    signing_fingerprint="$(${pkgs.openssh}/bin/ssh-keygen -lf "$HOME/.ssh/id_ed25519_git_signing.pub" | awk '{print $2}')"
    test "$auth_fingerprint" != "$signing_fingerprint"

    # Re-run: reconciles against the vault without generating or minting.
    "''${provision_env[@]}" atyrode provision git --yes 2> "$TMPDIR/provision-again.err"
    gh_calls="$(grep -cF 'ssh-key add' "$TMPDIR/gh-args")"
    if [[ "$gh_calls" != 2 ]]; then
      echo "re-run minted new keys: $gh_calls gh registrations" >&2
      cat "$TMPDIR/gh-args" >&2
      cat "$TMPDIR/provision-again.err" >&2
      exit 1
    fi

    # Blank-machine recovery: a second home materializes the same identities
    # from the vault alone; --persist writes the 0600 private files.
    recovery_home="$TMPDIR/recovery-home"
    mkdir -p "$recovery_home"
    HOME="$recovery_home" "''${provision_env[@]}" atyrode provision git --yes --persist >/dev/null 2>&1
    test "$(${pkgs.openssh}/bin/ssh-keygen -lf "$recovery_home/.ssh/id_ed25519.pub" | awk '{print $2}')" = "$auth_fingerprint"
    test "$(${pkgs.openssh}/bin/ssh-keygen -lf "$recovery_home/.ssh/id_ed25519_git_signing.pub" | awk '{print $2}')" = "$signing_fingerprint"
    test "$(stat -c %a "$recovery_home/.ssh/id_ed25519")" = 600
    test "$(stat -c %a "$recovery_home/.ssh/id_ed25519_git_signing")" = 600
    ${pkgs.openssh}/bin/ssh-agent -k >/dev/null 2>&1 || true

    # --- shared OMP auth broker: vault bootstrap, tunnel config, API keys -----
    publisher_home="$TMPDIR/auth-publisher"
    publisher_state="$publisher_home/.local/state"
    mkdir -p "$publisher_state/atyrode/omp-auth-broker"
    printf 'BROKER-TOKEN-TEST\n' > "$publisher_state/atyrode/omp-auth-broker/token"
    chmod 600 "$publisher_state/atyrode/omp-auth-broker/token"
    auth_publish_env=(env HOME="$publisher_home" XDG_STATE_HOME="$publisher_state" \
      ATYRODE_BW="$TMPDIR/bin/vault-bw")
    "''${auth_publish_env[@]}" atyrode auth broker publish --via alex@broker.example \
      > "$TMPDIR/auth-publish.out" 2> "$TMPDIR/auth-publish.err"
    test ! -s "$TMPDIR/auth-publish.out"
    ! grep -qF 'BROKER-TOKEN-TEST' "$TMPDIR/auth-publish.err"
    broker_note="$VAULT_STORE/$(printf 'note-%s' "$(printf '%s' 'OMP auth broker' | base64 -w0 | tr '+/=' '._-')")"
    jq -e '.version == 1
      and .url == "http://127.0.0.1:46171"
      and .sshHost == "alex@broker.example"
      and .token == "BROKER-TOKEN-TEST"' "$broker_note" >/dev/null

    client_home="$TMPDIR/auth-client"
    client_config="$client_home/.config"
    client_state="$client_home/.local/state"
    mkdir -p "$client_home"
    auth_client_env=(env HOME="$client_home" XDG_CONFIG_HOME="$client_config" \
      XDG_STATE_HOME="$client_state" ATYRODE_BW="$TMPDIR/bin/vault-bw" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/auth-systemctl")
    "''${auth_client_env[@]}" atyrode auth broker setup \
      > "$TMPDIR/auth-setup.out" 2> "$TMPDIR/auth-setup.err"
    auth_env_file="$client_config/atyrode/omp-auth-broker/env"
    test "$(stat -c %a "$auth_env_file")" = 600
    test -e "$TMPDIR/auth-broker-restarted"
    (
      set -u
      source "$auth_env_file"
      test "$OMP_AUTH_BROKER_MODE" = client
      test "$OMP_AUTH_BROKER_URL" = 'http://127.0.0.1:46171'
      test "$OMP_AUTH_BROKER_TOKEN" = BROKER-TOKEN-TEST
      test "$OMP_AUTH_BROKER_SSH_HOST" = alex@broker.example
    )
    auth_status="$("''${auth_client_env[@]}" atyrode auth broker status --json)"
    jq -e '.mode == "client" and .configured
      and .sshHost == "alex@broker.example"' <<<"$auth_status" >/dev/null
    ! grep -qF 'BROKER-TOKEN-TEST' <<<"$auth_status"

    printf 'sk-deepseek-test\n' |
      "''${auth_client_env[@]}" ATYRODE_FETCH="$TMPDIR/bin/auth-curl" \
        atyrode auth broker add-api-key deepseek \
        > "$TMPDIR/auth-add-key.out" 2> "$TMPDIR/auth-add-key.err"
    test ! -s "$TMPDIR/auth-add-key.out"
    ! grep -qF 'sk-deepseek-test' "$TMPDIR/auth-curl-args"
    ! grep -qF 'sk-deepseek-test' "$TMPDIR/auth-add-key.err"

    mkdir "$out"
  ''
