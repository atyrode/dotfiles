{ atyrode, pkgs }:

let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
  # A signing identity the check owns: the private key doctor git is pointed
  # at, and a signer set that reviews it. The CLI under test is built against
  # that set, so "authorized" is reachable without committing a fixture key to
  # the fleet's own allowed-signers.
  fixtureSigner = pkgs.runCommand "fixture-git-signer" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir -p "$out"
    ssh-keygen -q -t ed25519 -N "" -C "alex@tyrode.dev (fixture signing)" -f "$out/signing-key"
    ssh-keygen -q -t ed25519 -N "" -C "fixture authentication" -f "$out/auth-key"
    printf 'alex@tyrode.dev %s\n' "$(cut -d' ' -f1,2 "$out/signing-key.pub")" > "$out/allowed-signers"
  '';
  signerAtyrode = atyrode.override { gitAllowedSigners = "${fixtureSigner}/allowed-signers"; };
  githubProbe = pkgs.writeShellScript "fixture-github-keys" ''
    [[ "$1" == api ]] || exit 1
    printf '%s\n' "$*" >> "$GH_PROBE_LOG"
    case "$ATYRODE_GH_CASE" in
      denied) exit 1 ;;
      malformed) printf '{"message":"unavailable"}\n'; exit ;;
      invalid-key) printf '[{"key":"not-a-key"}]\n'; exit ;;
      unregistered) printf '[]\n'; exit ;;
    esac
    if [[ "''${*: -1}" == user/keys ]]; then
      jq -nc --arg key "$SIGNING_PUBLIC" '[{key:$key}]'
      [[ "$ATYRODE_GH_CASE" != registered ]] ||
        jq -nc --arg key "$AUTH_PUBLIC" '[{key:$key}]'
    else
      jq -nc --arg key "$AUTH_PUBLIC" '[{key:$key}]'
    fi
  '';
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
      "vars upload") printf 'upload\n' >> "$TMPDIR/fleet-order" ;;
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
      build)
        printf 'build\n' >> "$TMPDIR/fleet-order"
        printf '%s\n' "$ATYRODE_TEST_CANDIDATE"
        ;;
      copy) printf 'copy\n' >> "$TMPDIR/fleet-order" ;;
      *) exit 64 ;;
    esac
    EOF
    cat > "$TMPDIR/bin/fleet-ssh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/fleet-ssh-args"
    [[ -z "''${ATYRODE_TEST_SSH_UNREACHABLE:-}" ]] || exit 255
    if [[ "$*" == *'--preview-json'* ]]; then
      printf 'preview\n' >> "$TMPDIR/fleet-order"
      if [[ "''${ATYRODE_TEST_REMOTE_LEGACY:-0}" == 1 ]]; then
        printf '{"schemaVersion":1}\n'
      else
        printf '{"disruption":{"schemaVersion":1,"status":"%s","fingerprint":"%s","effects":[],"reasons":[]}}\n' \
          "''${ATYRODE_TEST_REMOTE_DISRUPTION:-safe}" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      fi
    elif [[ "$*" == *'--expected-disruption'* ]]; then
      [[ "$*" == *"--candidate $ATYRODE_TEST_CANDIDATE --expected-disruption aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]] || exit 65
      printf 'activate\n' >> "$TMPDIR/fleet-order"
    fi
    if [[ "$*" == *'atyrode doctor host --json'* ]]; then
      printf '%s\n' "{\"ok\":true,\"host\":\"''${ATYRODE_TEST_REPORTED_HOST:-fixture-nixos}\"}"
    fi
    EOF
    chmod +x "$TMPDIR/bin/age-keygen" \
      "$TMPDIR/bin/fleet-clan" "$TMPDIR/bin/fleet-nix" "$TMPDIR/bin/fleet-ssh"
    mkdir -p "$TMPDIR/repo"
    touch "$TMPDIR/repo/flake.nix"
    ${pkgs.gitMinimal}/bin/git -C "$TMPDIR/repo" init -q
    ${pkgs.gitMinimal}/bin/git -C "$TMPDIR/repo" add flake.nix
    ${pkgs.gitMinimal}/bin/git -C "$TMPDIR/repo" -c user.name=Fixture \
      -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture
    export PATH="$TMPDIR/bin:$PATH"
    # doctor git is read-only and reports classifications only. The identity it
    # judges is a placed private key: readable by this account, by nobody else,
    # and reviewed by the signer set the CLI was built with. No agent is
    # consulted, so none is started.
    (
      export HOME="$TMPDIR/git-doctor-home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export GH_CONFIG_DIR="$XDG_CONFIG_HOME/gh"
      export GIT_CONFIG_GLOBAL="$XDG_CONFIG_HOME/git/config"
      export GIT_CONFIG_NOSYSTEM=1
      unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN SSH_AUTH_SOCK GIT_SSH GIT_SSH_COMMAND
      mkdir -p "$XDG_CONFIG_HOME/git" "$GH_CONFIG_DIR" "$TMPDIR/git-doctor-repo" "$TMPDIR/placed"

      git_doctor=${pkgs.gitMinimal}/bin/git
      doctor_git() { ${signerAtyrode}/bin/atyrode doctor git "$@"; }
      install -m 0600 ${fixtureSigner}/signing-key "$TMPDIR/placed/signing-key"
      install -m 0600 ${fixtureSigner}/auth-key "$TMPDIR/placed/auth-key"
      managed_ssh="ssh -i $TMPDIR/placed/auth-key -o IdentitiesOnly=yes"
      "$git_doctor" config --global core.sshCommand "$managed_ssh"
      cp ${fixtureSigner}/allowed-signers "$XDG_CONFIG_HOME/git/allowed_signers"
      chmod 0644 "$XDG_CONFIG_HOME/git/allowed_signers"

      "$git_doctor" config --global user.signingKey "$TMPDIR/placed/signing-key"
      "$git_doctor" config --global gpg.format ssh
      "$git_doctor" config --global gpg.ssh.allowedSignersFile "$XDG_CONFIG_HOME/git/allowed_signers"
      "$git_doctor" config --global --add credential.https://github.com.helper ""
      "$git_doctor" config --global --add credential.https://github.com.helper \
        "${pkgs.gh}/bin/gh auth git-credential"
      "$git_doctor" config --global 'url.git@github.com:.pushInsteadOf' https://github.com/
      "$git_doctor" -C "$TMPDIR/git-doctor-repo" init -q
      "$git_doctor" -C "$TMPDIR/git-doctor-repo" remote add origin \
        https://github.com/atyrode/fixture.git

      cd "$TMPDIR/git-doctor-repo"
      # A signing key without an author is #590's shape: nothing can commit, so
      # the report must fail on that alone before anything else is judged.
      set +e
      doctor_git --json > "$TMPDIR/git-doctor-no-author.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.ok | not)
        and (.checks[] | select(.id == "author-identity") | .status == "failed" and .code == "author-unresolved")
        and (.checks[] | select(.id == "author-identity") | .actual == {name:false,email:false})
      ' "$TMPDIR/git-doctor-no-author.json" >/dev/null
      "$git_doctor" config --global user.name "Fixture Operator"
      "$git_doctor" config --global user.email fixture@example.invalid

      git_result="$(doctor_git --json)"
      jq -e '
        .schemaVersion == 1
        and .command == "doctor git"
        and .ok
        and .mutationBoundary == "read-only probes"
        and (.checks[] | select(.id == "author-identity") | .status == "ok")
        and (.checks[] | select(.id == "signing-key") | .actual.privateKey and .actual.permissionsPrivate)
        and (.checks[] | select(.id == "allowed-signers") | .actual.signingKeyAuthorized)
        and (.checks[] | select(.id == "remote-protocol") | .actual.httpsFetchUrls) == 1
        and (.checks[] | select(.id == "remote-protocol") | .actual.sshPushUrls) == 1
        and (.checks[] | select(.id == "gh-credential-helper") | .status) == "ok"
        and (.checks[] | select(.id == "gh-auth-storage") | .status) == "not-applicable"
      ' <<<"$git_result" >/dev/null
      # The report classifies; it never carries the key.
      grep -qF 'PRIVATE KEY' <<<"$git_result" && false

      export AUTH_PUBLIC="$(cat ${fixtureSigner}/auth-key.pub)"
      export SIGNING_PUBLIC="$(cat ${fixtureSigner}/signing-key.pub)"
      export ATYRODE_GH=${githubProbe}
      export ATYRODE_GH_CASE=registered
      export GH_PROBE_LOG="$TMPDIR/git-gh.log"
      auth_probe() {
        local expected_exit="$1" actual_exit
        shift
        set +e
        doctor_git "$@" --json > "$TMPDIR/git-auth.json" 2> "$TMPDIR/git-auth.err"
        actual_exit="$?"
        set -e
        test "$actual_exit" = "$expected_exit"
        grep -qF 'PRIVATE KEY' "$TMPDIR/git-auth.json" "$TMPDIR/git-auth.err" && false
        return 0
      }

      auth_probe 0
      test ! -e "$GH_PROBE_LOG"
      jq -e '.checks[] | select(.id == "authentication-registration") |
        .code == "offline" and .actual.registeredForAuthentication == null' \
        "$TMPDIR/git-auth.json" >/dev/null

      auth_probe 0 --online
      jq -e '.checks[] | select(.id == "authentication-registration") |
        .status == "ok" and .actual.registeredForAuthentication' "$TMPDIR/git-auth.json" >/dev/null

      ATYRODE_GH_CASE=signing-only auth_probe 69 --online
      jq -e '(.checks[] | select(.id == "signing-key") | .status == "ok")
        and (.checks[] | select(.id == "authentication-registration") |
          .code == "authentication-key-signing-only" and .actual.registeredAsSigningOnly
          and .actual.signingKeyRegisteredForAuthentication)' "$TMPDIR/git-auth.json" >/dev/null
      ATYRODE_GH_CASE=unregistered auth_probe 69 --online
      jq -e '.checks[] | select(.id == "authentication-registration") |
        .code == "authentication-key-unregistered" and .actual.checked' "$TMPDIR/git-auth.json" >/dev/null

      for response in denied malformed invalid-key; do
        ATYRODE_GH_CASE="$response" auth_probe 0 --online
        jq -e '.checks[] | select(.id == "authentication-registration") |
          .status == "warning" and .code == "registration-unverified"
          and (.actual.checked | not) and .actual.registeredForAuthentication == null' \
          "$TMPDIR/git-auth.json" >/dev/null
      done

      "$git_doctor" config --global --unset core.sshCommand
      auth_probe 69
      jq -e '(.checks[] | select(.id == "signing-key") | .status == "ok")
        and (.checks[] | select(.id == "authentication-key") |
          .code == "authentication-key-unselected")' "$TMPDIR/git-auth.json" >/dev/null
      "$git_doctor" config --global core.sshCommand "$managed_ssh"

      { printf '#!${pkgs.runtimeShell}\n'; printf 'touch "%s"\n' "$TMPDIR/ssh-executed"; } > "$TMPDIR/custom-ssh"
      chmod +x "$TMPDIR/custom-ssh"
      rm "$GH_PROBE_LOG"
      GIT_SSH_COMMAND="$TMPDIR/custom-ssh" auth_probe 0 --online
      jq -e '.checks[] | select(.id == "authentication-key") |
        .code == "ssh-command-unexamined"' "$TMPDIR/git-auth.json" >/dev/null
      test ! -e "$TMPDIR/ssh-executed"
      test ! -e "$GH_PROBE_LOG"
      "$git_doctor" config --local core.sshCommand "$managed_ssh"$'\n'"$TMPDIR/custom-ssh"
      auth_probe 0 --online
      jq -e '.checks[] | select(.id == "authentication-key") |
        .code == "ssh-command-unexamined"' "$TMPDIR/git-auth.json" >/dev/null
      test ! -e "$TMPDIR/ssh-executed"
      test ! -e "$GH_PROBE_LOG"
      "$git_doctor" config --local --unset core.sshCommand

      "$git_doctor" remote set-url origin git@gitlab.com:fixture/project.git
      auth_probe 0 --online
      test ! -e "$GH_PROBE_LOG"
      "$git_doctor" remote set-url origin https://github.com/atyrode/fixture.git
      unset ATYRODE_GH ATYRODE_GH_CASE

      "$git_doctor" config --global --unset-all 'url.git@github.com:.pushInsteadOf'
      "$git_doctor" config --global --unset-all credential.https://github.com.helper
      set +e
      doctor_git --json > "$TMPDIR/git-doctor-https.json"
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
      doctor_git --json > "$TMPDIR/git-doctor-store.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "credential-helper-plaintext") | .status) == "failed"
      ' "$TMPDIR/git-doctor-store.json" >/dev/null
      "$git_doctor" config --global --unset-all credential.helper

      printf 'https://fixture:placeholder@github.com\n' > "$HOME/.git-credentials"
      set +e
      doctor_git --json > "$TMPDIR/git-doctor-credential-file.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "credential-file-plaintext") | .status) == "failed"
      ' "$TMPDIR/git-doctor-credential-file.json" >/dev/null
      rm "$HOME/.git-credentials"

      # Drift from the managed signer set is one failure; a managed set that
      # does not name this machine's key is another, with the review as remedy.
      printf '# drift\n' >> "$XDG_CONFIG_HOME/git/allowed_signers"
      set +e
      doctor_git --json > "$TMPDIR/git-doctor-signers.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "allowed-signers") | .code) == "allowed-signers-drift"
      ' "$TMPDIR/git-doctor-signers.json" >/dev/null
      cp ${../../modules/home/git/allowed-signers} "$XDG_CONFIG_HOME/git/allowed_signers"
      set +e
      atyrode doctor git --json > "$TMPDIR/git-doctor-unreviewed.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "allowed-signers") | .code) == "signing-key-unreviewed"
        and (.checks[] | select(.id == "allowed-signers") | .remediation | contains("reviewed commit"))
      ' "$TMPDIR/git-doctor-unreviewed.json" >/dev/null
      cp ${fixtureSigner}/allowed-signers "$XDG_CONFIG_HOME/git/allowed_signers"

      # A private key another account can read is not private.
      chmod 0644 "$TMPDIR/placed/signing-key"
      set +e
      doctor_git --json > "$TMPDIR/git-doctor-key-mode.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "signing-key") | .actual.permissionsPrivate) == false
      ' "$TMPDIR/git-doctor-key-mode.json" >/dev/null
      chmod 0600 "$TMPDIR/placed/signing-key"

      # A public key at user.signingKey was the vault-era shape; it is not a
      # private key and cannot sign, so it is refused rather than passed.
      "$git_doctor" config --global user.signingKey "${fixtureSigner}/signing-key.pub"
      set +e
      doctor_git --json > "$TMPDIR/git-doctor-public.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "signing-key") | .code) == "signing-key-invalid"
        and (.checks[] | select(.id == "signing-key") | .actual.privateKey) == false
      ' "$TMPDIR/git-doctor-public.json" >/dev/null

      # No key at all is a portable profile, which signs nothing and is not
      # broken for it; the signer set is still judged on its own.
      "$git_doctor" config --global --unset user.signingKey
      unconfigured="$(doctor_git --json)"
      jq -e '
        .ok
        and (.checks[] | select(.id == "signing-key") | .status) == "not-applicable"
        and (.checks[] | select(.id == "allowed-signers") | .status) == "ok"
      ' <<<"$unconfigured" >/dev/null
      "$git_doctor" config --global user.signingKey "$TMPDIR/placed/signing-key"

      mkdir -p "$TMPDIR/git-doctor-bin"
    cat > "$TMPDIR/git-doctor-bin/gh" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' '{"hosts":{"github.com":[{"tokenSource":"keyring"}]}}'
    EOF
      chmod +x "$TMPDIR/git-doctor-bin/gh"
      export PATH="$TMPDIR/git-doctor-bin:$PATH"
      printf '%s\n' 'github.com:' '    users:' '        atyrode:' \
        > "$GH_CONFIG_DIR/hosts.yml"
      keyring_result="$(doctor_git --json)"
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
      doctor_git --json > "$TMPDIR/git-doctor-gh-plaintext.json"
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 69
      jq -e '
        (.checks[] | select(.id == "gh-auth-storage") | .status) == "failed"
        and (.checks[] | select(.id == "gh-auth-storage") | .actual.plaintextTokenFile)
      ' "$TMPDIR/git-doctor-gh-plaintext.json" >/dev/null
      grep -qF fixture-token-must-not-appear "$TMPDIR/git-doctor-gh-plaintext.json" && false
      rm "$GH_CONFIG_DIR/hosts.yml"

      set +e
      doctor_git --unknown >/dev/null 2>&1
      git_doctor_status="$?"
      set -e
      test "$git_doctor_status" = 64
    )

    # The vault verbs are gone with the ceremony they served (ADR 0008 step 6):
    # every secret is a clan var, and a Bitwarden session is nothing atyrode
    # asks for or knows how to open.
    for retired in 'vault status' 'vault login' 'vault get x' 'provision git'; do
      set +e
      # shellcheck disable=SC2086
      atyrode $retired >/dev/null 2>"$TMPDIR/retired.err"
      retired_status="$?"
      set -e
      test "$retired_status" = 64 || { echo "atyrode $retired must be refused as unknown (exit $retired_status)" >&2; exit 1; }
    done
    # --- fleet plan/apply: deploying a machine the operator is not sitting at -
    # The fixture host is a clan machine of this repository, so the whole
    # ceremony is this flake plus clan; no second repository, no vault, no
    # identity fetched at deploy time.
    fleet_test_env=(
      env
      ATYRODE_CLAN="$TMPDIR/bin/fleet-clan"
      ATYRODE_NIX="$TMPDIR/bin/fleet-nix"
      ATYRODE_SSH="$TMPDIR/bin/fleet-ssh"
      ATYRODE_GIT=${pkgs.gitMinimal}/bin/git
      ATYRODE_HOST=development-x86_64-linux
    )

    # A host clan cannot deploy is refused as a usage error, and the refusal
    # names the command that does converge it.
    set +e
    "''${fleet_test_env[@]}" atyrode fleet plan development-x86_64-linux \
      >"$TMPDIR/fleet-portable.out" 2>"$TMPDIR/fleet-portable.err"
    fleet_status="$?"
    set -e
    test "$fleet_status" = 64
    grep -qF 'atyrode apply' "$TMPDIR/fleet-portable.err"

    # A conventional checkout is not consent to select a deployment source.
    if "''${fleet_test_env[@]}" atyrode fleet plan fixture-nixos --json \
      >"$TMPDIR/fleet-implicit.out" 2>"$TMPDIR/fleet-implicit.err"; then
      echo 'fleet plan implicitly selected a checkout' >&2
      exit 1
    fi
    test ! -e "$TMPDIR/fleet-ssh-args"
    test ! -e "$TMPDIR/clan-args"

    fleet_plan="$("''${fleet_test_env[@]}" atyrode fleet plan fixture-nixos \
      --repo "$TMPDIR/repo" --json 2>"$TMPDIR/fleet-plan.err")"
    jq -e --arg repo "$TMPDIR/repo" \
      --arg revision "$(${pkgs.gitMinimal}/bin/git -C "$TMPDIR/repo" rev-parse HEAD)" \
      '.ok and .action == "plan" and .host == "fixture-nixos"
      and .repository == $repo and .resolvedRevision == $revision and .dirty == false
      and .targetHost == "alex@target.example" and .hostKeyCheck == "strict"
      and .buildHost == "localhost"
      and .drvPath == "/nix/store/test-fixture-nixos-system.drv"
      and .mutationBoundary == "read-only until fleet apply"' <<<"$fleet_plan" >/dev/null
    grep -qF 'vars check fixture-nixos' "$TMPDIR/clan-args"
    grep -qF 'BatchMode=yes -o StrictHostKeyChecking=yes' "$TMPDIR/fleet-ssh-args"
    grep -qF 'alex@target.example true' "$TMPDIR/fleet-ssh-args"
    # A plan activates nothing, whatever else it reports.
    test ! -e "$TMPDIR/fleet-order"
    printf '# changed\n' >> "$TMPDIR/repo/flake.nix"
    "''${fleet_test_env[@]}" atyrode fleet plan fixture-nixos --repo "$TMPDIR/repo" --json \
      2>"$TMPDIR/fleet-dirty.err" | jq -e '.dirty' >/dev/null

    # Vars that are not generated stop the deployment before it touches the
    # machine, and the remedy names the command that generates them.
    set +e
    "''${fleet_test_env[@]}" ATYRODE_TEST_VARS_INCOMPLETE=1 \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      >"$TMPDIR/fleet-vars.out" 2>"$TMPDIR/fleet-vars.err"
    fleet_status="$?"
    set -e
    test "$fleet_status" = 70
    grep -qF 'clan vars generate fixture-nixos' "$TMPDIR/fleet-vars.err"
    test ! -e "$TMPDIR/fleet-order"

    # An unreachable machine is a preflight failure, not a half-finished
    # deployment.
    set +e
    "''${fleet_test_env[@]}" ATYRODE_TEST_SSH_UNREACHABLE=1 \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      >"$TMPDIR/fleet-unreachable.out" 2>"$TMPDIR/fleet-unreachable.err"
    fleet_status="$?"
    set -e
    test "$fleet_status" = 69
    test ! -e "$TMPDIR/fleet-order"

    fleet_apply="$("''${fleet_test_env[@]}" \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      2>"$TMPDIR/fleet-apply.err")"
    jq -e '.ok and .action == "apply" and .host == "fixture-nixos"
      and .targetHost == "alex@target.example" and .verified' <<<"$fleet_apply" >/dev/null
    grep -qF "vars upload fixture-nixos --flake $TMPDIR/repo" "$TMPDIR/clan-args"
    grep -qF "copy --to ssh-ng://alex@target.example --no-check-sigs $ATYRODE_TEST_CANDIDATE" \
      "$TMPDIR/fleet-nix-args"
    grep -qF 'atyrode doctor host --json' "$TMPDIR/fleet-ssh-args"
    test "$(cat "$TMPDIR/fleet-order")" = "$(printf 'build\ncopy\npreview\nupload\nactivate')"

    # --yes skips confirmation, never a missing or unsafe target report.
    for remote_state in blocked unknown legacy; do
      : > "$TMPDIR/fleet-order"
      legacy=0
      [[ "$remote_state" != legacy ]] || legacy=1
      if "''${fleet_test_env[@]}" ATYRODE_TEST_REMOTE_DISRUPTION="$remote_state" \
        ATYRODE_TEST_REMOTE_LEGACY="$legacy" atyrode fleet apply fixture-nixos \
        --repo "$TMPDIR/repo" --yes --json >/dev/null 2>"$TMPDIR/fleet-refused.err"; then
        echo "fleet activated a $remote_state report" >&2
        exit 1
      fi
      test "$(cat "$TMPDIR/fleet-order")" = "$(printf 'build\ncopy\npreview')"
    done

    # A machine that activated but answers as somebody else is a failure: the
    # deployment ran through activation and the wrong closure is live, so the
    # order shows the activation happened and the exit is the software failure
    # rather than a preflight refusal.
    : > "$TMPDIR/fleet-order"
    set +e
    "''${fleet_test_env[@]}" ATYRODE_TEST_REPORTED_HOST=someone-else \
      atyrode fleet apply fixture-nixos --repo "$TMPDIR/repo" --yes --json \
      >"$TMPDIR/fleet-mismatch.out" 2>"$TMPDIR/fleet-mismatch.err"
    fleet_status="$?"
    set -e
    test "$fleet_status" = 70
    test "$(cat "$TMPDIR/fleet-order")" = "$(printf 'build\ncopy\npreview\nupload\nactivate')"

    cat > "$TMPDIR/bin/auth-systemctl" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      '--user cat atyrode-omp-auth-brokers.service') exit 0 ;;
      '--user show -P ActiveState atyrode-omp-auth-brokers.service') printf 'active\n' ;;
      '--user restart '*) touch "$TMPDIR/auth-broker-restarted" ;;
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

    # --- shared OMP auth broker: placed token, status, API keys --------------
    # The bearer token is a shared clan var sops-nix places and Home Manager
    # links to ~/.omp/auth-broker.token; atyrode reads the link and never
    # writes, restarts, or prints anything. Which side of the broker a host is
    # on comes from fleet/auth-broker.json: dev-01 serves, every other clan
    # machine tunnels, a portable profile has no side at all.
    client_home="$TMPDIR/auth-client"
    mkdir -p "$client_home/.omp"
    auth_client_env=(env HOME="$client_home" ATYRODE_SYSTEMCTL="$TMPDIR/bin/auth-systemctl")
    for retired in publish setup; do
      if "''${auth_client_env[@]}" atyrode auth broker "$retired" >/dev/null 2>&1; then
        echo "auth broker $retired must be gone: the token is a clan var, not a vault item" >&2
        exit 1
      fi
    done

    # Before the var is placed the link dangles: status says so without
    # inventing anything, on both sides of the broker.
    ln -s /run/secrets/vars/omp-auth-broker/token "$client_home/.omp/auth-broker.token"
    auth_status="$("''${auth_client_env[@]}" ATYRODE_HOST=wsl atyrode auth broker status --json)"
    jq -e --arg tokenPath "$client_home/.omp/auth-broker.token" '
      .mode == "tunnel" and .host == "dev-01" and .configured == false
      and .tokenPath == $tokenPath and .service == "active"' <<<"$auth_status" >/dev/null
    auth_status="$("''${auth_client_env[@]}" ATYRODE_HOST=dev-01 atyrode auth broker status --json)"
    jq -e '.mode == "serve" and .host == "dev-01" and .configured == false' <<<"$auth_status" >/dev/null
    auth_status="$("''${auth_client_env[@]}" ATYRODE_HOST=development-x86_64-linux atyrode auth broker status --json)"
    jq -e '.mode == "none" and .host == "dev-01"' <<<"$auth_status" >/dev/null

    # add-api-key needs the token to authenticate the upload; without it the
    # failure names the generate step rather than a vault or a setup verb.
    set +e
    printf 'sk-deepseek-test\n' |
      "''${auth_client_env[@]}" ATYRODE_HOST=wsl ATYRODE_FETCH="$TMPDIR/bin/auth-curl" \
        atyrode auth broker add-api-key deepseek \
        > "$TMPDIR/auth-add-key-unplaced.out" 2> "$TMPDIR/auth-add-key-unplaced.err"
    add_key_status="$?"
    set -e
    test "$add_key_status" = 66
    grep -qF 'clan vars generate wsl' "$TMPDIR/auth-add-key-unplaced.err"
    test ! -e "$TMPDIR/auth-curl-args"

    # The placed token: status reports it without printing it, in either
    # output shape, and the upload carries it only inside the 0600 curl
    # config, never in argv or stderr.
    rm "$client_home/.omp/auth-broker.token"
    printf 'BROKER-TOKEN-TEST' > "$client_home/.omp/auth-broker.token"
    chmod 600 "$client_home/.omp/auth-broker.token"
    auth_status="$("''${auth_client_env[@]}" ATYRODE_HOST=wsl atyrode auth broker status --json)"
    jq -e '.mode == "tunnel" and .configured == true' <<<"$auth_status" >/dev/null
    grep -qF 'BROKER-TOKEN-TEST' <<<"$auth_status" && false
    "''${auth_client_env[@]}" ATYRODE_HOST=wsl atyrode auth broker status > "$TMPDIR/auth-status.out"
    grep -qF 'BROKER-TOKEN-TEST' "$TMPDIR/auth-status.out" && false

    printf 'sk-deepseek-test\n' |
      "''${auth_client_env[@]}" ATYRODE_HOST=wsl ATYRODE_FETCH="$TMPDIR/bin/auth-curl" \
        atyrode auth broker add-api-key deepseek \
        > "$TMPDIR/auth-add-key.out" 2> "$TMPDIR/auth-add-key.err"
    test ! -s "$TMPDIR/auth-add-key.out"
    grep -qF 'sk-deepseek-test' "$TMPDIR/auth-curl-args" && false
    grep -qF 'BROKER-TOKEN-TEST' "$TMPDIR/auth-curl-args" && false
    grep -qF 'sk-deepseek-test' "$TMPDIR/auth-add-key.err" && false
    grep -qF 'BROKER-TOKEN-TEST' "$TMPDIR/auth-add-key.err" && false
    test ! -e "$TMPDIR/auth-broker-restarted"

    mkdir "$out"
  ''
