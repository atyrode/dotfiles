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
    cat > "$TMPDIR/bin/bw" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/bw-args"
    case "$*" in
      status) printf '%s\n' '{"status":"unlocked"}' ;;
      sync|lock|login) ;;
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
      'list items --search '*) printf '%s\n' '[]' ;;
      'get template item')
        printf '%s\n' '{"type":2,"name":"","notes":null,"secureNote":{"type":0}}'
        ;;
      'get item vault-existing-id')
        printf '%s\n' '{"id":"vault-existing-id","name":"vault-existing","type":2,"notes":"VAULT-OLD-SECRET","secureNote":{"type":0}}'
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
    chmod +x "$TMPDIR/bin/bw" "$TMPDIR/bin/age-keygen" "$TMPDIR/bin/infra-nix" "$TMPDIR/bin/infra-ssh"
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

    infra_apply="$("''${infra_test_env[@]}" atyrode infra apply --repo "$TMPDIR/infra" --yes --json)"
    jq -e '.ok and .action == "apply" and .machine == "tyrode-dev-01"
      and .targetHost == "alex@target.example" and .verified
      and .privateMaterialPrinted == false' <<<"$infra_apply" >/dev/null
    grep -qF 'clan machines update tyrode-dev-01' "$TMPDIR/infra-nix-args"
    grep -qF -- '--target-host alex@target.example --build-host localhost --upload-inputs --host-key-check strict' \
      "$TMPDIR/infra-nix-args"
    grep -qF 'alex@target.example atyrode doctor host --json' "$TMPDIR/infra-ssh-args"
    ! grep -qF 'AGE-SECRET-KEY-1TESTONLY' <<<"$infra_apply"

    mkdir "$out"
  ''
