{ atyrode, pkgs }:

let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
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
      status) printf '{"status":"%s"}\n' "''${ATYRODE_TEST_BW_STATUS:-unlocked}" ;;
      login|'login --raw'|sync|lock) ;;
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
    cat > "$TMPDIR/bin/fleet-clan" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/clan-args"
    case "''${1:-} ''${2:-}" in
      "vars check") [[ -z "''${ATYRODE_TEST_VARS_INCOMPLETE:-}" ]] || exit 1 ;;
      "machines update") ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/fleet-nix" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/fleet-nix-args"
    case "''${1:-}" in
      eval)
        case "$*" in
          *targetHost*) printf '%s\n' 'alex@target.example' ;;
          *) printf '%s\n' '/nix/store/test-fixture-nixos-system.drv' ;;
        esac
        ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/fleet-ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/fleet-ssh-args"
    [[ -z "''${ATYRODE_TEST_SSH_UNREACHABLE:-}" ]] || exit 255
    if [[ "$*" == *'atyrode doctor host --json'* ]]; then
      printf '%s\n' "{\"ok\":true,\"host\":\"''${ATYRODE_TEST_REPORTED_HOST:-fixture-nixos}\"}"
    fi
    EOF
    chmod +x "$TMPDIR/bin/bw" "$TMPDIR/bin/age-keygen" \
      "$TMPDIR/bin/fleet-clan" "$TMPDIR/bin/fleet-nix" "$TMPDIR/bin/fleet-ssh"
    mkdir -p "$TMPDIR/repo"
    touch "$TMPDIR/repo/flake.nix"
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
      read -r _ signing_type signing_blob < ${../../modules/home/git/allowed-signers}
      printf '%s %s fixture-signing-key\n' "$signing_type" "$signing_blob" \
        > "$HOME/.ssh/id_ed25519_git_signing.pub"
      chmod 0644 "$HOME/.ssh/id_ed25519_git_signing.pub"
      cp ${../../modules/home/git/allowed-signers} "$XDG_CONFIG_HOME/git/allowed_signers"
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
      cp ${../../modules/home/git/allowed-signers} "$XDG_CONFIG_HOME/git/allowed_signers"

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
    # Reading the vault says nothing: a status probe is not a mutation, and an
    # operator wants the four commands that act, not the forty that look.
    "''${vault_test_env[@]}" atyrode vault status --json \
      >"$TMPDIR/vault-status-out" 2>"$TMPDIR/vault-status-err"
    jq -e '.status == "unlocked"' "$TMPDIR/vault-status-out" >/dev/null
    test ! -s "$TMPDIR/vault-status-err"
    vault_get="$("''${vault_test_env[@]}" atyrode vault get vault-existing \
      2>"$TMPDIR/vault-get-err")"
    test "$vault_get" = VAULT-OLD-SECRET
    # A sync pulls the vault over the network, so it is shown even on a read.
    grep -qE '^\$ .*bw sync$' "$TMPDIR/vault-get-err"

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
    # Writing to the operator's live Bitwarden account is a mutation like any
    # other, so it is announced -- and announcing means printing argv next to a
    # secret, which is exactly why the printed line is checked for it. The note
    # body reaches bw on stdin, so the announcement carries a verb and an id.
    grep -qE '^\$ .*bw sync$' "$TMPDIR/vault-put-err"
    grep -qE '^\$ .*bw create item$' "$TMPDIR/vault-put-err"
    ! grep -qF 'VAULT-NEW-SECRET' "$TMPDIR/vault-put-err"

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
    # --raw and nothing else: a plain login ends by printing the session key it
    # minted as copy-paste advice, which puts the one secret this flow exists to
    # protect into the terminal, the scrollback, and any captured transcript.
    # The raw form emits only the key, on stdout, where it is captured and
    # never shown.
    grep -qxF 'login --raw' "$TMPDIR/bw-args"

    # --- fleet plan/apply: deploying a machine the operator is not sitting at -
    # The fixture host is a clan machine of this repository, so the whole
    # ceremony is this flake plus clan; no second repository, no vault, no
    # identity fetched at deploy time.
    fleet_test_env=(
      env
      ATYRODE_CLAN="$TMPDIR/bin/fleet-clan"
      ATYRODE_NIX="$TMPDIR/bin/fleet-nix"
      ATYRODE_SSH="$TMPDIR/bin/fleet-ssh"
      ATYRODE_HOST=platform-01
    )

    # A host clan cannot deploy is refused by name, and the refusal says which
    # command does converge it.
    if "''${fleet_test_env[@]}" atyrode fleet plan platform-01 \
      >"$TMPDIR/fleet-standalone.out" 2>"$TMPDIR/fleet-standalone.err"; then
      echo 'fleet plan must refuse a standalone Home Manager host' >&2
      exit 1
    fi
    grep -qF 'converges with atyrode apply' "$TMPDIR/fleet-standalone.err"

    fleet_plan="$("''${fleet_test_env[@]}" atyrode fleet plan fixture-nixos \
      --repo "$TMPDIR/repo" --json 2>"$TMPDIR/fleet-plan.err")"
    jq -e '.ok and .action == "plan" and .host == "fixture-nixos"
      and .targetHost == "alex@target.example" and .hostKeyCheck == "strict"
      and .buildHost == "localhost"
      and .drvPath == "/nix/store/test-fixture-nixos-system.drv"
      and .mutationBoundary == "read-only until fleet apply"' <<<"$fleet_plan" >/dev/null
    grep -qF 'vars check fixture-nixos' "$TMPDIR/clan-args"
    grep -qF 'BatchMode=yes -o StrictHostKeyChecking=yes' "$TMPDIR/fleet-ssh-args"
    grep -qF 'alex@target.example true' "$TMPDIR/fleet-ssh-args"
    # A plan activates nothing, whatever else it reports.
    ! grep -qF 'machines update' "$TMPDIR/clan-args"

    # Vars that are not generated stop the deployment before it touches the
    # machine, and the remedy names the command that generates them.
    if "''${fleet_test_env[@]}" ATYRODE_TEST_VARS_INCOMPLETE=1 \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      >"$TMPDIR/fleet-vars.out" 2>"$TMPDIR/fleet-vars.err"; then
      echo 'fleet apply must refuse a machine whose vars are incomplete' >&2
      exit 1
    fi
    grep -qF 'clan vars generate fixture-nixos' "$TMPDIR/fleet-vars.err"
    ! grep -qF 'machines update' "$TMPDIR/clan-args"

    # An unreachable machine is a preflight failure, not a half-finished
    # deployment.
    if "''${fleet_test_env[@]}" ATYRODE_TEST_SSH_UNREACHABLE=1 \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      >"$TMPDIR/fleet-unreachable.out" 2>"$TMPDIR/fleet-unreachable.err"; then
      echo 'fleet apply must refuse an unreachable machine' >&2
      exit 1
    fi
    grep -qF 'did not answer a strict-host-key SSH check' "$TMPDIR/fleet-unreachable.err"
    ! grep -qF 'machines update' "$TMPDIR/clan-args"

    fleet_apply="$("''${fleet_test_env[@]}" \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      2>"$TMPDIR/fleet-apply.err")"
    jq -e '.ok and .action == "apply" and .host == "fixture-nixos"
      and .targetHost == "alex@target.example" and .verified' <<<"$fleet_apply" >/dev/null
    grep -qF "machines update fixture-nixos --flake $TMPDIR/repo" "$TMPDIR/clan-args"
    grep -qF -- '--target-host alex@target.example --build-host localhost --upload-inputs --host-key-check strict' \
      "$TMPDIR/clan-args"
    grep -qF 'alex@target.example atyrode doctor host --json' "$TMPDIR/fleet-ssh-args"
    grep -qE '^  \$ .*clan machines update fixture-nixos' "$TMPDIR/fleet-apply.err"

    # A machine that activated but answers as somebody else is a failure: the
    # deployment exited zero and the wrong closure is live.
    if "''${fleet_test_env[@]}" ATYRODE_TEST_REPORTED_HOST=someone-else \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      >"$TMPDIR/fleet-mismatch.out" 2>"$TMPDIR/fleet-mismatch.err"; then
      echo 'fleet apply must fail when the machine does not verify its identity' >&2
      exit 1
    fi
    grep -qF 'does not report itself as fixture-nixos' "$TMPDIR/fleet-mismatch.err"

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
    grep -qF 'not yet in modules/home/git/allowed-signers' "$TMPDIR/provision-fresh.err"
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
