{
  atyrode,
  pkgs,
  productionAtyrode,
  productionHost,
}:

let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
  atyrodeSource = import ../lib/atyrode-source.nix { inherit pkgs; };
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

    # Assertions here are bare `test` and `grep`, so without this a failure
    # exits silently and the build log ends mid-scenario with nothing to read.
    # Name the line and the command instead.
    trap 'echo "check failed at line $LINENO: $BASH_COMMAND" >&2' ERR
    cat > "$TMPDIR/bin/fake-systemd-run" <<'EOF'
    #!${pkgs.runtimeShell}
    mkdir -p "$TMPDIR/fake-systemd"
    printf '%s\n' "$*" >> "$TMPDIR/fake-systemd/run-args"
    unit=""
    path_forwarded=0
    pty=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --unit=*) unit="''${1#--unit=}"; shift ;;
        --pty) pty=1; shift ;;
        --setenv=*)
          export "''${1#--setenv=}"
          [[ "''${1#--setenv=}" != PATH=* ]] || path_forwarded=1
          shift
          ;;
        --) shift; break ;;
        *) shift ;;
      esac
    done
    # systemd starts a unit from the user manager's environment, not the
    # submitter's, so the unit only sees what --setenv forwards. Model that for
    # PATH: inheriting the caller's PATH here would hide the interop-PATH gap
    # that makes winget.exe unreachable from the real apply worker on WSL.
    [[ "$path_forwarded" == 1 ]] || export PATH=/usr/bin:/bin
    [[ -n "$unit" && $# -gt 0 ]] || exit 64
    # --pty connects the unit to the caller's terminal, and systemd-run then
    # waits for it and reports its exit status. Model exactly that: same stdio,
    # foreground, same status - a unit that cannot see this stdin cannot be
    # asked anything, which is the whole point of the flag.
    if [[ "$pty" == 1 ]]; then
      exec "$@"
    fi
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
        # systemctl separates answers from failures to answer: 0 active,
        # 3 inactive, 4 no such unit, and 1 when the query itself failed.
        # A bus that cannot answer is not evidence the unit is gone.
        bus="$TMPDIR/fake-systemd/bus-unanswerable"
        if [[ -s "$bus" ]]; then
          remaining="$(cat "$bus")"
          if [[ "$remaining" -gt 0 ]]; then
            printf '%s\n' "$((remaining - 1))" > "$bus"
            exit 1
          fi
        fi
        pid_file="$TMPDIR/fake-systemd/$unit.pid"
        [[ -r "$pid_file" ]] || exit 4
        kill -0 "$(cat "$pid_file")" 2>/dev/null || exit 3
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

    # ATYRODE_GIT / ATYRODE_NH are tool-substitution seams honoured ONLY under
    # test hooks. The wrappers below live outside PATH, so they are reachable
    # exclusively through the env var: a test-hooks build must run them, and a
    # production build must refuse the command rather than silently driving the
    # real git/nh against the live store.
    mkdir -p "$TMPDIR/seam"
    for seam_tool in git nh; do
      cat > "$TMPDIR/seam/$seam_tool" <<'EOF'
    #!${pkgs.runtimeShell}
    tool="''${0##*/}"
    printf '%s\n' "$*" >> "$TMPDIR/seam/$tool.used"
    exec "$TMPDIR/bin/$tool" "$@"
    EOF
      chmod +x "$TMPDIR/seam/$seam_tool"
    done
    rm -f "$TMPDIR/seam/git.used" "$TMPDIR/seam/nh.used"
    ATYRODE_GIT="$TMPDIR/seam/git" ATYRODE_NH="$TMPDIR/seam/nh" \
      atyrode apply --repo "$HOME/nix-dotfiles" --dry-run >/dev/null
    test -s "$TMPDIR/seam/git.used" \
      || { echo 'a test-hooks build must resolve git through ATYRODE_GIT' >&2; exit 1; }
    test -s "$TMPDIR/seam/nh.used" \
      || { echo 'a test-hooks build must resolve nh through ATYRODE_NH' >&2; exit 1; }
    for seam in git:ATYRODE_GIT nh:ATYRODE_NH; do
      seam_tool="''${seam%%:*}"
      seam_var="''${seam##*:}"
      rm -f "$TMPDIR/seam/$seam_tool.used"
      set +e
      ( unset ATYRODE_GIT ATYRODE_NH ATYRODE_NIX_ENV ATYRODE_NIX_STORE ATYRODE_GEN_PROFILE
        export "$seam_var=$TMPDIR/seam/$seam_tool"
        exec ${productionAtyrode}/bin/atyrode apply --plan
      ) > /dev/null 2> "$TMPDIR/prod-seam.err"
      seam_status="$?"
      set -e
      test "$seam_status" = 64 \
        || { echo "production apply must refuse $seam_var (exit $seam_status): $(cat "$TMPDIR/prod-seam.err")" >&2; exit 1; }
      grep -qF "$seam_var is set" "$TMPDIR/prod-seam.err" \
        || { echo "production refusal must name $seam_var" >&2; exit 1; }
      test ! -e "$TMPDIR/seam/$seam_tool.used" \
        || { echo "a production build must never reach the $seam_var stub" >&2; exit 1; }
    done

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

    # The CLI reads and drives this machine, so it must see the machine's own
    # programs no matter what PATH the caller had. A bootstrap that has just
    # activated still holds the PATH it started with: on a real Darwin run that
    # made every managed tool report missing, `gh` unavailable, and the babel
    # ceremony unable to find babel -- a healthy machine reported as broken.
    #
    # `nix-locate` is a declared tool, so doctor has an opinion about it. Here
    # it exists only inside the activated profile and nowhere on the PATH the
    # caller supplies, which is exactly the post-activation shape.
    mkdir -p "$HOME/.nix-profile/bin"
    printf '#!${pkgs.runtimeShell}\nexit 0\n' > "$HOME/.nix-profile/bin/nix-locate"
    chmod +x "$HOME/.nix-profile/bin/nix-locate"
    stripped="${pkgs.coreutils}/bin:${pkgs.jq}/bin"
    ! PATH="$stripped" command -v nix-locate >/dev/null
    # Non-zero because the stripped PATH leaves other declared tools missing;
    # the assertion is about the one that must be found regardless.
    env PATH="$stripped" "$(command -v atyrode)" doctor tools --json > "$TMPDIR/adopted.json" || true
    jq -e --arg profile "$HOME/.nix-profile/bin/nix-locate" '
      any(.[]; .name == "nix-index" and .status == "ok" and .path == $profile)
    ' "$TMPDIR/adopted.json" >/dev/null

    atyrode apply --repo "$HOME/nix-dotfiles" --plan --json | jq -e '
      .host == "alex-x86_64-linux"
      and .backend == "nh-home"
      and .source == "local"
      and .revision == "0123456789ab"
      and .resolvedRevision == "0123456789abcdef0123456789abcdef01234567"
      and .mutationBoundary == "activation only after preflight"
    ' >/dev/null
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"

    # A plan is a list of what will change, not a dump of what was resolved,
    # and printing one changes nothing. This is the output an operator reads
    # before committing, so it has to name the same steps the run then walks.
    rm -f "$TMPDIR/nh-args"
    atyrode apply --repo "$HOME/nix-dotfiles" --plan >/dev/null 2>"$TMPDIR/plan.err"
    grep -qE '^  1\. Rebuild and switch alex-x86_64-linux through nh-home\.$' "$TMPDIR/plan.err"
    grep -qE '^  2\. Record alex-x86_64-linux as the activated host\.$' "$TMPDIR/plan.err"
    grep -qE '^  3\. Converge the account login shell\.$' "$TMPDIR/plan.err"
    grep -qE '^  4\. Review the provisioning surfaces' "$TMPDIR/plan.err"
    grep -qE "^  5\. Render this machine's agent context\.\$" "$TMPDIR/plan.err"
    grep -qF 'No changes were made. Drop --plan to run this.' "$TMPDIR/plan.err"
    test ! -e "$TMPDIR/nh-args"
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"

    # The machine identity (ADR 0008 step 3, amended): the age key clan vars
    # are decrypted with, made on the machine by the machine and registered
    # with clan by its public half alone. age-keygen is stubbed for a
    # deterministic recipient, and the private line it writes is a sentinel
    # no output may ever carry.
    cat > "$TMPDIR/bin/age-keygen" <<'EOF'
    #!${pkgs.runtimeShell}
    minted_recipient=age1freshmachine00000000000000000000000000000000000000000000000
    case "''${1:-}" in
      -o)
        umask 077
        printf '# created: fixture\n# public key: %s\nAGE-SECRET-KEY-1FIXTUREONLY\n' \
          "$minted_recipient" > "$2"
        printf 'Public key: %s\n' "$minted_recipient" >&2
        ;;
      -y) sed -n 's/^# public key: //p' "$2" ;;
      *) exit 64 ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/age-keygen"
    export ATYRODE_AGE_KEYGEN="$TMPDIR/bin/age-keygen"
    minted_recipient=age1freshmachine00000000000000000000000000000000000000000000000
    fixture_recipient=age1fixturemachine0000000000000000000000000000000000000000000000
    identity_probe() { # host status code
      ATYRODE_HOST="$1" atyrode doctor provisioning --json |
        jq -e --arg status "$2" --arg code "$3" '
          .surfaces[] | select(.id == "machine-identity")
          | .status == $status and (.code // "") == $code
            and .command == "atyrode identity init" and .declinable == false
        ' >/dev/null
    }
    # A standalone Home Manager host is not a clan machine: it reads no
    # secret, so there is no key to make. The verb refuses with the reason,
    # the probe is not-applicable, and an apply never mentions a ceremony
    # this host cannot have.
    identity_probe alex-x86_64-linux not-applicable not-a-clan-machine
    set +e
    atyrode identity show > "$TMPDIR/identity-home.out" 2> "$TMPDIR/identity-home.err"
    identity_status="$?"
    set -e
    test "$identity_status" = 65
    test ! -s "$TMPDIR/identity-home.out"
    test "$(wc -l < "$TMPDIR/identity-home.err")" = 1
    grep -qF 'alex-x86_64-linux is not a clan machine' "$TMPDIR/identity-home.err"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/identity-apply.err" ||
      { cat "$TMPDIR/identity-apply.err" >&2; exit 1; }
    ! grep -qF 'machine identity' "$TMPDIR/identity-apply.err"
    # A clan machine with no key: show says so and exits with a finding, the
    # record names the path sops-nix reads (modules/shared/clan-machine.nix
    # sets the same one), and the probe names the ceremony.
    identity_probe fixture-nixos incomplete not-configured
    set +e
    ATYRODE_HOST=fixture-nixos atyrode identity show > "$TMPDIR/identity-none.out" 2> "$TMPDIR/identity-none.err"
    identity_status="$?"
    set -e
    test "$identity_status" = 69
    test ! -s "$TMPDIR/identity-none.out"
    grep -qF 'no machine identity yet for fixture-nixos; create one with: atyrode identity init' \
      "$TMPDIR/identity-none.err"
    ATYRODE_HOST=fixture-nixos atyrode identity show --json | jq -e '
      .recipient == null and .registered == false and .registration == null
      and .keyFile == "/var/lib/sops-nix/key.txt" and .machineClass == "nixos"' >/dev/null
    # The key is root's, so a sandbox that cannot elevate stops before
    # anything is written, and says what is missing.
    set +e
    ATYRODE_HOST=fixture-nixos atyrode identity init > "$TMPDIR/identity-nosudo.out" 2> "$TMPDIR/identity-nosudo.err"
    identity_status="$?"
    set -e
    test "$identity_status" = 69
    grep -qF 'belongs to root, and sudo is unavailable' "$TMPDIR/identity-nosudo.err"
    # The ceremony as the operator would see it. sudo is stubbed to run the
    # announced argv as the sandbox user, and the machine's root-owned paths
    # are relocated under a scratch root: every step is announced as the
    # elevation it is, the key lands at the modes a secret demands, the
    # public half is published beside it, and the minted recipient -- which
    # clan does not register yet -- is printed as the one command that does.
    machine_root="$TMPDIR/machine"
    export _ATYRODE_TEST_IDENTITY_ROOT="$machine_root"
    machine_key="$machine_root/var/lib/sops-nix/key.txt"
    machine_recipient="$machine_root/etc/atyrode/machine.pub"
    {
      printf '#!${pkgs.runtimeShell}\n'
      printf 'args=()\n'
      printf 'while [ "$#" -gt 0 ]; do\n'
      printf '  case "$1" in --) ;; -o) if [ "''${2:-}" = root ]; then shift; else args+=("$1"); fi ;; *) args+=("$1") ;; esac\n'
      printf '  shift\n'
      printf 'done\n'
      printf 'exec "''${args[@]}"\n'
    } > "$TMPDIR/bin/sudo"
    chmod +x "$TMPDIR/bin/sudo"
    ATYRODE_HOST=fixture-nixos atyrode identity init > "$TMPDIR/identity-init.out" 2> "$TMPDIR/identity-init.err"
    grep -qF 'this host activates as root, so the key is root'"'"'s: each step below elevates and says so' "$TMPDIR/identity-init.err"
    grep -qE "^\\$ sudo -- .*install -d -m 0700 -o root $machine_root/var/lib/sops-nix\$" "$TMPDIR/identity-init.err"
    grep -qE "^\\$ sudo -- $TMPDIR/bin/age-keygen -o $machine_key\$" "$TMPDIR/identity-init.err"
    grep -qE "^\\$ sudo -- $TMPDIR/bin/age-keygen -y $machine_key\$" "$TMPDIR/identity-init.err"
    grep -qE "^\\$ sudo -- .*install -m 0644 -o root .* $machine_recipient\$" "$TMPDIR/identity-init.err"
    grep -qF "wrote $machine_key (root, mode 0600, directory mode 0700) and published its recipient at $machine_recipient" \
      "$TMPDIR/identity-init.err"
    grep -qF 'register it with clan in a checkout of this repository on the Mac, then commit sops/machines/fixture-nixos/key.json:' \
      "$TMPDIR/identity-init.err"
    grep -qE "^  \\$ clan secrets machines add fixture-nixos $minted_recipient\$" "$TMPDIR/identity-init.err"
    grep -qF 'once a generator is declared, clan vars generate fixture-nixos encrypts its values to this machine' \
      "$TMPDIR/identity-init.err"
    test -f "$machine_key"
    test "$(stat -c %a "$machine_key")" = 600
    test "$(stat -c %a "''${machine_key%/*}")" = 700
    test "$(stat -c %a "$machine_recipient")" = 644
    test "$(cat "$machine_recipient")" = "$minted_recipient"
    grep -qF 'AGE-SECRET-KEY-1FIXTUREONLY' "$machine_key"
    # A key clan does not register is the one state where the fix is a
    # command in a checkout rather than here: the probe and the verb print
    # exactly that command, and init repeats it without touching a key that
    # values may already be encrypted to.
    identity_probe fixture-nixos degraded not-registered
    ATYRODE_HOST=fixture-nixos atyrode doctor provisioning --json | jq -e --arg recipient "$minted_recipient" '
      .surfaces[] | select(.id == "machine-identity")
      | (.summary | contains("sops/machines/fixture-nixos/key.json"))
        and .remediation == "in a checkout on the Mac, run: clan secrets machines add fixture-nixos " + $recipient' >/dev/null
    ATYRODE_HOST=fixture-nixos atyrode identity show > "$TMPDIR/identity-show.out" 2> "$TMPDIR/identity-show.err"
    test "$(cat "$TMPDIR/identity-show.out")" = "$minted_recipient"
    grep -qE "^  \\$ clan secrets machines add fixture-nixos $minted_recipient\$" "$TMPDIR/identity-show.err"
    ATYRODE_HOST=fixture-nixos atyrode identity show --json | jq -e --arg recipient "$minted_recipient" '
      .recipient == $recipient and .registered == false
      and .registration == "clan secrets machines add fixture-nixos " + $recipient
      and .privateMaterialPrinted == false' >/dev/null
    ATYRODE_HOST=fixture-nixos atyrode identity init > "$TMPDIR/identity-again.out" 2> "$TMPDIR/identity-again.err"
    grep -qF "fixture-nixos already has a machine identity at $machine_key; keeping it" "$TMPDIR/identity-again.err"
    grep -qE "^  \\$ clan secrets machines add fixture-nixos $minted_recipient\$" "$TMPDIR/identity-again.err"
    ! grep -qF 'sudo' "$TMPDIR/identity-again.err"
    grep -qF 'AGE-SECRET-KEY-1FIXTUREONLY' "$machine_key"
    # Registered: the published recipient is the one the fixture sops tree
    # records under sops/machines/fixture-nixos, so every reader agrees.
    printf '%s\n' "$fixture_recipient" > "$machine_recipient"
    identity_probe fixture-nixos ok ""
    ATYRODE_HOST=fixture-nixos atyrode identity show > "$TMPDIR/identity-registered.out" 2> "$TMPDIR/identity-registered.err"
    test "$(cat "$TMPDIR/identity-registered.out")" = "$fixture_recipient"
    grep -qF 'registered with clan as sops/machines/fixture-nixos/key.json' "$TMPDIR/identity-registered.err"
    ATYRODE_HOST=fixture-nixos atyrode identity show --json | jq -e --arg recipient "$fixture_recipient" '
      .recipient == $recipient and .registered == true
      and .registration == "clan secrets machines add fixture-nixos " + $recipient' >/dev/null
    ATYRODE_HOST=fixture-nixos atyrode identity init > "$TMPDIR/identity-settled.out" 2> "$TMPDIR/identity-settled.err"
    grep -qF "recipient $fixture_recipient is registered with clan as sops/machines/fixture-nixos/key.json" \
      "$TMPDIR/identity-settled.err"
    # The private half never reaches a terminal, in any of the runs above.
    for identity_output in "$TMPDIR"/identity-*.out "$TMPDIR"/identity-*.err; do
      ! grep -qF 'AGE-SECRET-KEY' "$identity_output"
    done
    rm -f "$TMPDIR/bin/sudo"
    unset _ATYRODE_TEST_IDENTITY_ROOT

    # The operator identity (ADR 0008 step 3): the age key that edits secrets,
    # minted inside the Mac's Secure Enclave. The plugin is stubbed for a
    # deterministic recipient -- the one the fixture sops tree registers as
    # user alex -- and the identity line it writes is a sentinel no output
    # may ever carry. The verb and its probe gate on the registry's system,
    # so a Linux sandbox can walk the Mac's states by naming the host.
    cat > "$TMPDIR/bin/age-plugin-se" <<'EOF'
    #!${pkgs.runtimeShell}
    fixture_recipient=age1se1fixtureoperator00000000000000000000000000000000000000000000
    [[ "''${1:-}" == keygen && "''${2:-}" == --access-control=any-biometry-or-passcode && "''${3:-}" == -o && -n "''${4:-}" ]] || exit 64
    umask 077
    printf '# created: fixture\n# access control: any biometry or passcode\n# public key: %s\nAGE-PLUGIN-SE-1FIXTUREONLY\n' \
      "$fixture_recipient" > "$4"
    printf 'Public key: %s\n' "$fixture_recipient"
    EOF
    chmod +x "$TMPDIR/bin/age-plugin-se"
    export ATYRODE_AGE_PLUGIN_SE="$TMPDIR/bin/age-plugin-se"
    operator_key="$XDG_CONFIG_HOME/sops/age/keys.txt"
    operator_recipient=age1se1fixtureoperator00000000000000000000000000000000000000000000
    operator_probe() { # host status code
      ATYRODE_HOST="$1" atyrode doctor provisioning --json |
        jq -e --arg status "$2" --arg code "$3" '
          .surfaces[] | select(.id == "operator-identity")
          | .status == $status and (.code // "") == $code
            and .command == "atyrode operator init" and .declinable == false
            and (.implies | contains("never leaves the Secure Enclave"))
        ' >/dev/null
    }
    # Off the Mac there is nothing to have: the verb refuses in one sentence
    # and the probe is not-applicable, on a host that really is Linux.
    operator_probe alex-x86_64-linux not-applicable platform-not-darwin
    set +e
    atyrode operator show > "$TMPDIR/operator-linux.out" 2> "$TMPDIR/operator-linux.err"
    operator_status="$?"
    set -e
    test "$operator_status" = 65
    test ! -s "$TMPDIR/operator-linux.out"
    test "$(wc -l < "$TMPDIR/operator-linux.err")" = 1
    grep -qF 'alex-x86_64-linux is not it' "$TMPDIR/operator-linux.err"
    test ! -e "$operator_key"
    # On the Mac with no key: show says so and exits with a finding, and the
    # probe names the ceremony.
    operator_probe alex-aarch64-darwin incomplete not-configured
    set +e
    ATYRODE_HOST=alex-aarch64-darwin atyrode operator show > "$TMPDIR/operator-none.out" 2> "$TMPDIR/operator-none.err"
    operator_status="$?"
    set -e
    test "$operator_status" = 69
    test ! -s "$TMPDIR/operator-none.out"
    grep -qF "no operator identity yet at $operator_key" "$TMPDIR/operator-none.err"
    grep -qF 'create one with: atyrode operator init' "$TMPDIR/operator-none.err"
    # init says Touch ID is coming, announces the one command, lands the key
    # at the modes a secret demands, and -- the fixture sops tree already
    # registering the recipient it minted -- reports the operator registered.
    ATYRODE_HOST=alex-aarch64-darwin atyrode operator init > "$TMPDIR/operator-init.out" 2> "$TMPDIR/operator-init.err"
    grep -qF 'macOS will prompt for Touch ID' "$TMPDIR/operator-init.err"
    grep -qE "^\\$ .*age-plugin-se keygen --access-control=any-biometry-or-passcode -o $operator_key\$" "$TMPDIR/operator-init.err"
    grep -qF "wrote $operator_key (mode 0600, directory mode 0700)" "$TMPDIR/operator-init.err"
    grep -qF "recipient $operator_recipient is registered with clan as sops/users/alex/key.json" "$TMPDIR/operator-init.err"
    test "$(cat "$TMPDIR/operator-init.out")" = "Public key: $operator_recipient"
    test -f "$operator_key"
    test "$(stat -c %a "$operator_key")" = 600
    test "$(stat -c %a "''${operator_key%/*}")" = 700
    grep -qF 'AGE-PLUGIN-SE-1FIXTUREONLY' "$operator_key"
    operator_probe alex-aarch64-darwin ok ""
    ATYRODE_HOST=alex-aarch64-darwin atyrode operator show > "$TMPDIR/operator-show.out" 2> "$TMPDIR/operator-show.err"
    test "$(cat "$TMPDIR/operator-show.out")" = "$operator_recipient"
    grep -qF 'registered with clan as sops/users/alex/key.json' "$TMPDIR/operator-show.err"
    # A second init keeps the key: the enclave could not give a replaced one
    # back, and files may already be encrypted to it.
    ATYRODE_HOST=alex-aarch64-darwin atyrode operator init > "$TMPDIR/operator-again.out" 2> "$TMPDIR/operator-again.err"
    grep -qF "$operator_key already exists; keeping it" "$TMPDIR/operator-again.err"
    ! grep -qF 'age-plugin-se' "$TMPDIR/operator-again.err"
    test ! -s "$TMPDIR/operator-again.out"
    grep -qF 'AGE-PLUGIN-SE-1FIXTUREONLY' "$operator_key"
    # A recipient clan does not register: the probe and the verb print
    # exactly the command that registers it, and say the recovery user is
    # registered already.
    sed -i 's/^# public key: .*/# public key: age1se1unregistered0000000000000000000000000000000000000000000000/' "$operator_key"
    operator_probe alex-aarch64-darwin degraded not-registered
    ATYRODE_HOST=alex-aarch64-darwin atyrode doctor provisioning --json | jq -e '
      .surfaces[] | select(.id == "operator-identity")
      | (.summary | contains("sops/users/alex/key.json"))
        and .remediation == "in a checkout on this Mac, run: clan secrets users add alex age1se1unregistered0000000000000000000000000000000000000000000000"' >/dev/null
    ATYRODE_HOST=alex-aarch64-darwin atyrode operator show > "$TMPDIR/operator-unregistered.out" 2> "$TMPDIR/operator-unregistered.err"
    grep -qF 'register it with clan in a checkout of this repository on this Mac, then commit sops/users/alex/key.json:' \
      "$TMPDIR/operator-unregistered.err"
    grep -qE '^  \$ clan secrets users add alex age1se1unregistered0000000000000000000000000000000000000000000000$' \
      "$TMPDIR/operator-unregistered.err"
    grep -qF 'alex-recovery is registered already' "$TMPDIR/operator-unregistered.err"
    # The day-zero Mac: a software key in the file sops reads. It is neither
    # overwritten nor mistaken for the operator identity, and the way out is
    # said rather than taken.
    printf '# created: fixture\n# public key: age1softwarefixture0000\nAGE-SECRET-KEY-1FIXTUREONLY\n' > "$operator_key"
    operator_probe alex-aarch64-darwin incomplete not-configured
    set +e
    ATYRODE_HOST=alex-aarch64-darwin atyrode operator init > "$TMPDIR/operator-foreign.out" 2> "$TMPDIR/operator-foreign.err"
    operator_status="$?"
    set -e
    test "$operator_status" = 65
    grep -qF "$operator_key already exists; keeping it" "$TMPDIR/operator-foreign.err"
    grep -qF 'holds no Secure Enclave recipient' "$TMPDIR/operator-foreign.err"
    grep -qF 'AGE-SECRET-KEY-1FIXTUREONLY' "$operator_key"
    rm -f "$operator_key"
    # Neither identity line ever reaches a terminal, in any of the runs above.
    for operator_output in "$TMPDIR"/operator-*.out "$TMPDIR"/operator-*.err; do
      ! grep -qF 'AGE-PLUGIN-SE-1' "$operator_output"
      ! grep -qF 'AGE-SECRET-KEY' "$operator_output"
    done

    LC_CTYPE=UTF-8 atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-success.err" ||
      { cat "$TMPDIR/apply-success.err" >&2; exit 1; }
    # A successful apply with neither Babel's storage document nor a success
    # stamp names the provisioning ceremony without failing the activation.
    # This harness has no terminal, so the non-interactive path must name the
    # ceremony rather than offer it -- and it must still state what configuring
    # it implies, because a machine that only says "not configured" leaves the
    # operator to go and find out what they would be agreeing to.
    grep -qF 'Babel session archive is not configured' "$TMPDIR/apply-success.err"
    grep -qF 'arms the hourly timer that publishes them' "$TMPDIR/apply-success.err"
    grep -qF 'configure with: atyrode provision babel' "$TMPDIR/apply-success.err"
    # No question is asked where nothing can answer it.
    ! grep -qF 'now?' "$TMPDIR/apply-success.err"
    # No prompt without a terminal, and nothing an operator cannot retype: not a
    # checkout path, and not the store path the ceremony actually lives at.
    ! grep -qiF 'bitwarden password' "$TMPDIR/apply-success.err"
    ! grep -qF 'nix-dotfiles/scripts' "$TMPDIR/apply-success.err"
    ! grep -qF '/nix/store' "$TMPDIR/apply-success.err"
    ! grep -qiF 'set up session backup' "$TMPDIR/apply-success.err"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = alex-x86_64-linux
    test -z "$(find "$XDG_STATE_HOME/atyrode" -name '.dotfiles-config.*' -print -quit)"
    test "$(cat "$TMPDIR/nh-locale")" = C.UTF-8

    # The babel ceremony ends at a master-password prompt, so a vault that is
    # not even logged in is an earlier blocker than the one the offer is about,
    # and an operator who is not told answers yes to a program that cannot
    # start. Both readings are driven through the CLI's own bw seam: the
    # wrapper prefixes the real bw onto PATH and adopt_activated_path only
    # appends, so a stub anywhere on PATH could never win.
    mkdir -p "$TMPDIR/vaultbin"
    {
      printf '#!%s\n' "${pkgs.runtimeShell}"
      printf 'case "$1" in\n'
      printf '  status) cat %s ;;\n' "$TMPDIR/bw-status.json"
      printf '  config) printf %s ;;\n' "'https://vault.bitwarden.eu'"
      printf '  login) printf %s > %s ;;\n' "'{\"status\":\"unlocked\"}'" "$TMPDIR/bw-status.json"
      printf '  *) exit 1 ;;\n'
      printf 'esac\n'
    } > "$TMPDIR/vaultbin/bw"
    chmod +x "$TMPDIR/vaultbin/bw"
    # The second link of the babel chain. A sandbox can neither hold nor
    # acquire a real Clever Cloud session, so the stub keeps its own: `profile`
    # succeeds once `login` has run.
    {
      printf '#!%s\n' "${pkgs.runtimeShell}"
      printf 'case "$1" in\n'
      printf '  profile) test -e %s ;;\n' "$TMPDIR/clever-session"
      printf '  login) touch %s ;;\n' "$TMPDIR/clever-session"
      printf '  *) exit 1 ;;\n'
      printf 'esac\n'
    } > "$TMPDIR/vaultbin/clever"
    chmod +x "$TMPDIR/vaultbin/clever"
    touch "$TMPDIR/clever-session"
    printf '%s\n' '{"status":"unauthenticated"}' > "$TMPDIR/bw-status.json"
    ATYRODE_BW="$TMPDIR/vaultbin/bw" atyrode apply --repo "$HOME/nix-dotfiles" \
      >/dev/null 2>"$TMPDIR/apply-vault-out.err" ||
      { cat "$TMPDIR/apply-vault-out.err" >&2; exit 1; }
    grep -qF 'it needs a Bitwarden session first: atyrode vault login' \
      "$TMPDIR/apply-vault-out.err"
    # Never a bare `bw login`: this fleet's account is on the EU cloud, where
    # the bw default fails a first login with a misleading "invalid master
    # password" -- the obvious advice is the advice that wastes an evening.
    if grep -qF 'bw login' "$TMPDIR/apply-vault-out.err"; then
      echo 'the vault remedy pointed at the login that fails on this fleet' >&2
      exit 1
    fi
    # The claim is a reading, not a constant: a reachable vault stops the offer
    # from mentioning login at all.
    printf '%s\n' '{"status":"unlocked"}' > "$TMPDIR/bw-status.json"
    ATYRODE_BW="$TMPDIR/vaultbin/bw" atyrode apply --repo "$HOME/nix-dotfiles" \
      >/dev/null 2>"$TMPDIR/apply-vault-in.err" ||
      { cat "$TMPDIR/apply-vault-in.err" >&2; exit 1; }
    grep -qF 'Babel session archive is not configured' "$TMPDIR/apply-vault-in.err"
    if grep -qF 'needs a Bitwarden session' "$TMPDIR/apply-vault-in.err"; then
      echo 'the babel offer reported a login blocker against a reachable vault' >&2
      exit 1
    fi

    # A prerequisite this CLI owns is something to offer, not homework to set.
    # Declining leaves the surface alone and never starts a ceremony that
    # cannot finish; the offer is separate from the surface's own because
    # answering no here makes that question moot.
    printf '%s\n' '{"status":"unauthenticated"}' > "$TMPDIR/bw-status.json"
    blocker_no="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 ATYRODE_BW="$TMPDIR/vaultbin/bw" ATYRODE_CLEVER="$TMPDIR/vaultbin/clever" \
      atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" || true
    grep -qF 'Babel session archive needs a Bitwarden session, and without it' <<<"$blocker_no" \
      || { echo "a blocker must say what declining costs: $blocker_no" >&2; exit 1; }
    grep -qF 'run atyrode vault login now?' <<<"$blocker_no" \
      || { echo "a blocker must be offered, not recited: $blocker_no" >&2; exit 1; }
    grep -qF 'stays unconfigured until atyrode vault login runs' <<<"$blocker_no" \
      || { echo 'declining a prerequisite must say what it leaves behind' >&2; exit 1; }
    if grep -qF 'babel-storage-configure' <<<"$blocker_no"; then
      echo 'declining the prerequisite must not start the ceremony anyway' >&2
      exit 1
    fi

    # Accepting runs it here, announced by the name the offer used rather than
    # the resolved store path: the operator was asked about `atyrode vault
    # login`, so that is what the transcript has to show starting.
    printf '%s\n' '{"status":"unauthenticated"}' > "$TMPDIR/bw-status.json"
    blocker_yes="$(printf 'y\ny\n' | _ATYRODE_TEST_TTY=1 ATYRODE_BW="$TMPDIR/vaultbin/bw" ATYRODE_CLEVER="$TMPDIR/vaultbin/clever" \
      atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" || true
    grep -qE '^  \$ atyrode vault login$' <<<"$blocker_yes" \
      || { echo "the prerequisite must be announced as it was offered: $blocker_yes" >&2; exit 1; }
    if grep -qE '^  \$ /nix/store/[a-z0-9]{32}-atyrode' <<<"$blocker_yes"; then
      echo 'the announcement must not disagree with the question above it' >&2
      exit 1
    fi
    # Prerequisites waterfall in declared order, each offered on its own with
    # what declining costs, and the surface only asked about once every link
    # holds. Both links are settled here, then the surface itself is declined,
    # which proves the chain never runs a ceremony the operator did not accept.
    printf '%s\n' '{"status":"unauthenticated"}' > "$TMPDIR/bw-status.json"
    rm -f "$TMPDIR/clever-session"
    chain_out="$(printf 'y\ny\nn\n' | _ATYRODE_TEST_TTY=1 ATYRODE_BW="$TMPDIR/vaultbin/bw" \
      ATYRODE_CLEVER="$TMPDIR/vaultbin/clever" atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" || true
    grep -qF 'needs a Clever Cloud session, and without it the archive add-ons cannot be looked up' <<<"$chain_out" \
      || { echo "the second link must be offered with its cost: $chain_out" >&2; exit 1; }
    grep -qE '^  \$ clever login$' <<<"$chain_out" \
      || { echo "the clever login must be announced as offered: $chain_out" >&2; exit 1; }
    test -e "$TMPDIR/clever-session" \
      || { echo 'accepting the clever link must actually run the login' >&2; exit 1; }
    vault_line="$(grep -nF '$ atyrode vault login' <<<"$chain_out" | head -1 | cut -d: -f1)"
    clever_line="$(grep -nF '$ clever login' <<<"$chain_out" | head -1 | cut -d: -f1)"
    test "$vault_line" -lt "$clever_line" \
      || { echo 'links must be offered in declared order' >&2; exit 1; }
    grep -qF 'run atyrode provision babel for alex-x86_64-linux now?' <<<"$chain_out" \
      || { echo 'once every link holds the surface itself is offered' >&2; exit 1; }
    if grep -qF 'babel-storage-configure' <<<"$chain_out"; then
      echo 'declining the surface must not run the ceremony' >&2
      exit 1
    fi
    touch "$TMPDIR/clever-session"
    rm -f "$XDG_CONFIG_HOME/babel/storage.json" \
      "$XDG_STATE_HOME/atyrode/provisioning-declined"

    # The CLI carries its own bw, and a sandbox has no session, so every
    # vault-backed surface below would otherwise be offered its login first.
    # That is the right behaviour and it is asserted directly above; the
    # scenarios that follow are about the surfaces themselves, so the vault
    # stops being a free variable here.
    printf '%s\n' '{"status":"unlocked"}' > "$TMPDIR/bw-status.json"
    export ATYRODE_BW="$TMPDIR/vaultbin/bw"
    export ATYRODE_CLEVER="$TMPDIR/vaultbin/clever"

    # Transparency is a contract, not a courtesy. An operator watching an apply
    # has to be able to see what it will do, what it is doing and why, and
    # whether each part worked -- and read all of it again once the scrollback
    # is gone. A step that announces itself and then goes quiet is the shape
    # this replaces: it is indistinguishable from a step that hung.
    grep -qE '^1/5 Rebuild and switch alex-x86_64-linux through nh-home$' "$TMPDIR/apply-success.err"
    grep -qE '^2/5 Record alex-x86_64-linux as the activated host$' "$TMPDIR/apply-success.err"
    grep -qE '^3/5 Converge the account login shell$' "$TMPDIR/apply-success.err"
    grep -qE '^4/5 Review the provisioning surfaces' "$TMPDIR/apply-success.err"
    grep -qE "^5/5 Render this machine's agent context$" "$TMPDIR/apply-success.err"
    # ... and a home-manager apply writes nothing this user could not write, so
    # it must not warn about a password prompt that will never arrive.
    if grep -qF 'nh elevates' "$TMPDIR/apply-success.err"; then
      echo 'a home-manager apply warned about an elevation it never performs' >&2
      exit 1
    fi
    # Five steps, five verdicts: no step may end without one.
    test "$(grep -cE '^  (ok|skip|failed)( |$)' "$TMPDIR/apply-success.err")" -eq 5
    # And the reason a step is running, in the vocabulary of what decided it.
    grep -qF 'why fleet/system-boundary.json declares' "$TMPDIR/apply-success.err"
    grep -qF 'why fleet/provisioning.json declares 8 surfaces' "$TMPDIR/apply-success.err"
    grep -qF "wrote $XDG_STATE_HOME/atyrode/dotfiles-config" "$TMPDIR/apply-success.err"
    grep -qF 'Apply complete for alex-x86_64-linux' "$TMPDIR/apply-success.err"

    # The agent context (ADR 0008 step 2). apply's last step rendered it, and
    # every tool file on the machine is a symlink to this one path, so what it
    # says is what every agent here starts from: the operator policy first,
    # then the generated section naming this host and the rest of the fleet.
    context_file="$XDG_CONFIG_HOME/agents/AGENTS.md"
    grep -qE '^  \$ atyrode context render$' "$TMPDIR/apply-success.err"
    grep -qF "wrote $context_file" "$TMPDIR/apply-success.err"
    test -f "$context_file"
    test ! -L "$context_file"
    test "$(stat -c %a "$context_file")" = 644
    test -z "$(find "$XDG_CONFIG_HOME/agents" -name '.AGENTS.md.*' -print -quit)"
    grep -qxF '# Operator policy' "$context_file"
    grep -qxF '## This machine' "$context_file"
    test "$(grep -nxF '# Operator policy' "$context_file" | cut -d: -f1)" \
      -lt "$(grep -nxF '## This machine' "$context_file" | cut -d: -f1)"
    grep -qF -- '- Host: `alex-x86_64-linux` -- Headless x86_64 Linux development machine' "$context_file"
    grep -qF -- '- `alex-aarch64-darwin`: Primary Apple Silicon Mac' "$context_file"
    grep -qF -- '- `development-x86_64-linux`: Portable' "$context_file"
    grep -qF 'None yet; secrets arrive with ADR 0008 step 3' "$context_file"
    grep -qF -- '- Fleet cache substituter: `https://atyrode-nix-cache.cellar-c2.services.clever-cloud.com`' "$context_file"
    grep -qF 'does not trust it yet' "$context_file"
    grep -qF 'No canonical clone root is declared for this host' "$context_file"
    grep -qF 'Never edit by hand.' "$context_file"
    # Under the session stubs exported above, every CLI is reported as it is:
    # the vault unlocked, clever logged in, gh (real, no account here) not --
    # and a missing session names the exact command that acquires it. A token
    # planted in the environment is the falsification: gh would use it and bw
    # would use it, and neither may reach the file. Assembled at run time so
    # the fixture never holds a string a scanner would flag.
    planted_gh_token="ghp_$(printf 'FIXTURE%.0s' 1 2 3 4 5)"
    GH_TOKEN="$planted_gh_token" BW_SESSION=fixture-session-secret-value \
      atyrode context render 2>"$TMPDIR/context-render.err"
    grep -qF "wrote $context_file" "$TMPDIR/context-render.err"
    grep -qF -- '- `gh`: not authenticated; acquire a GitHub session with `gh auth login`' "$context_file"
    grep -qF -- '- `clever`: authenticated' "$context_file"
    grep -qF -- '- `bw`: authenticated, vault unlocked' "$context_file"
    ! grep -qF 'ghp_FIXTURE' "$context_file"
    ! grep -qF 'fixture-session-secret' "$context_file"
    ! grep -qE 'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|[A-Za-z0-9+/]{80,}==' "$context_file"
    # show prints the same document render writes; --json is the section as
    # data, and it says the same things the prose does.
    atyrode context show | sed '/^## This machine$/,$d' > "$TMPDIR/context-shown-policy"
    sed '/^## This machine$/,$d' "$context_file" | diff - "$TMPDIR/context-shown-policy"
    atyrode context show | grep -qF -- '- Host: `alex-x86_64-linux`'
    atyrode context --json | jq -e '
      .schemaVersion == 1
      and .command == "context"
      and .host.id == "alex-x86_64-linux"
      and (.fleet | map(.id) | index("alex-aarch64-darwin") != null)
      and (.fleet | map(.id) | index("alex-x86_64-linux") == null)
      and .authentication.gh.authenticated == false
      and .authentication.gh.acquire == "gh auth login"
      and .authentication.clever.authenticated == true
      and .authentication.bitwarden.vault == "unlocked"
      and (.secrets.readable | length) == 0
      and .fleetCache.substituter == "https://atyrode-nix-cache.cellar-c2.services.clever-cloud.com"
      and .fleetCache.trusted == false
      and .cloneRoot == null
      and (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    ' >/dev/null
    ! atyrode context render --json >/dev/null 2>&1
    ! atyrode context render show >/dev/null 2>&1

    # doctor owns the verdict on the file it does not write: fresh is ok, a
    # week old or from another published revision is stale, hand-written is
    # unreadable, and absent is a to-do apply settles. Every remedy is the one
    # command that writes it.
    context_probe() {
      atyrode doctor provisioning --json |
        jq -e --arg status "$1" --arg code "$2" '
          .surfaces[] | select(.id == "agent-context")
          | .status == $status and (.code // "") == $code
            and (if $status == "ok" then .remediation == null
                 elif $status == "degraded" then .remediation == "atyrode context render"
                 else .command == "atyrode context render" and .declinable == false end)
        ' >/dev/null
    }
    context_probe ok ""
    stamped_revision="$(sed -nE 's/^Generated at [^ ]+ from atyrode\/dotfiles revision ([^ ]+) by .*$/\1/p' "$context_file")"
    test -n "$stamped_revision"
    cp "$context_file" "$TMPDIR/context-fresh"
    sed -i "s/^Generated at [^ ]* /Generated at $(date -u -d '8 days ago' +%FT%TZ) /" "$context_file"
    context_probe degraded context-stale
    cp "$TMPDIR/context-fresh" "$context_file"
    # A published build knows its revision and holds the file to it; a
    # development build has nothing to compare and judges by age alone.
    sed -i 's/ revision [^ ]* by / revision 0123456789abcdef0123456789abcdef01234567 by /' "$context_file"
    if [[ "$stamped_revision" =~ ^[0-9a-f]{40}$ ]]; then
      context_probe degraded context-stale
    else
      context_probe ok ""
    fi
    printf '# hand-written\n' > "$context_file"
    context_probe degraded context-unreadable
    rm -f "$context_file"
    context_probe incomplete not-configured
    # Off a terminal the review names the surface; the render step then
    # settles it in the same run, so the machine never stays without one.
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/context-heal.err" ||
      { cat "$TMPDIR/context-heal.err" >&2; exit 1; }
    grep -qF 'configure with: atyrode context render' "$TMPDIR/context-heal.err"
    test -f "$context_file"
    context_probe ok ""

    # The durable half. A terminal scrolls; this is what a diagnosis reads
    # three weeks later, so it records the same story with timestamps and is
    # readable only by its owner.
    run_log="$(find "$XDG_STATE_HOME/atyrode/logs" -name '*-apply.log' | sort | tail -1)"
    test -n "$run_log"
    test -n "$(find "$run_log" -perm 600 -print -quit)"
    grep -qE 'run: env LC_ALL=C\.UTF-8 .*nh home switch' "$run_log"
    grep -qE '^[0-9-]{10}T[0-9:]{8}Z step 1/5: Rebuild and switch' "$run_log"
    grep -qF 'apply finished for alex-x86_64-linux' "$run_log"

    # With a terminal, the same state offers the ceremony instead of narrating
    # it. This is the path a real machine takes, so it must ask before doing
    # anything, name the identity it would configure, and honour a refusal by
    # leaving a way back in -- while the activation itself still succeeds.
    decline_out="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" ||
      { printf '%s\n' "$decline_out" >&2; exit 1; }
    printf '%s\n' "$decline_out" | grep -qF 'the hourly timer is installed but archives nothing'
    printf '%s\n' "$decline_out" | grep -qF 'run atyrode provision babel for alex-x86_64-linux now?'
    printf '%s\n' "$decline_out" | grep -qF 'this machine will not be asked again'
    # Declining must not have configured anything.
    test ! -e "$XDG_CONFIG_HOME/babel/storage.json"

    # A decline is a per-machine answer, not a per-run one: the whole point of
    # recording it is that the next apply does not re-ask a question already
    # answered. Same state, same terminal, and this time no question at all.
    ledger="$XDG_STATE_HOME/atyrode/provisioning-declined"
    grep -q '^babel-archive	' "$ledger"
    again_out="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" ||
      { printf '%s\n' "$again_out" >&2; exit 1; }
    if printf '%s\n' "$again_out" | grep -qF 'run atyrode provision babel'; then
      echo 'atyrode: a recorded decline was re-asked on the next apply' >&2
      exit 1
    fi
    # Still reported, though: declined is not the same as absent, and "what is
    # missing here" has to include what is missing on purpose.
    atyrode doctor provisioning --json |
      jq -e '.pending == 0
        and (.surfaces[] | select(.id == "babel-archive")
             | .status == "declined" and .code == "declined-by-operator")' >/dev/null
    rm -f "$ledger"

    # A supervised apply an operator is watching keeps that operator's terminal,
    # and a captured job has none of what follows from that: the job is
    # submitted with --pty rather than as a detached --service-type=exec unit,
    # the offer the WORKER raises reaches this stdin and is answered from it,
    # and the activation output arrives here instead of in a log the CLI
    # replays once it is all over. The log keeps an account of where the output
    # went so apply-status cannot claim to hold a transcript it never captured.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    live_out="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 \
      _ATYRODE_TEST_SYSTEMD_AVAILABLE=1 \
      ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" ||
      { printf '%s\n' "$live_out" >&2; exit 1; }
    grep -qF -- '--pty' "$TMPDIR/fake-systemd/run-args"
    if grep -qF -- '--service-type=exec' "$TMPDIR/fake-systemd/run-args"; then
      echo 'a live apply was submitted as a detached job' >&2
      exit 1
    fi
    printf '%s\n' "$live_out" | grep -qF 'run atyrode provision babel for alex-x86_64-linux now?'
    printf '%s\n' "$live_out" | grep -qF 'mutation boundary:'
    if printf '%s\n' "$live_out" | grep -qF 'reconnect with: atyrode apply-status'; then
      echo 'a live apply pointed the operator at output they were already reading' >&2
      exit 1
    fi
    # An apply that silently becomes someone else's process is the definition
    # of opaque, so the handoff names the unit that now owns it. In prose, not
    # as argv: this one command carries the whole forwarded PATH, and printing
    # it would bury the run it introduces under kilobytes of store paths. The
    # log takes the argv instead, which is where a diagnosis looks anyway.
    printf '%s\n' "$live_out" | grep -qF 'this apply runs in atyrode-apply.service, holding this terminal'
    if printf '%s\n' "$live_out" | grep -qF -- '--setenv=PATH='; then
      echo 'the systemd handoff printed its forwarded environment to the terminal' >&2
      exit 1
    fi
    submit_log="$(find "$XDG_STATE_HOME/atyrode/logs" -name '*-apply.log' | sort | tail -1)"
    grep -qF 'handoff: ' "$submit_log"
    grep -qF -- '--pty' "$submit_log"
    live_job="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    jq -e '.live' "$XDG_STATE_HOME/atyrode/apply-jobs/$live_job/metadata.json" >/dev/null
    jq -e '.phase == "succeeded" and .exitCode == 0' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$live_job/result.json" >/dev/null
    grep -qF 'streamed live to the operator terminal' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$live_job/output.log"
    if grep -qF 'mutation boundary:' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$live_job/output.log"; then
      echo 'a live apply captured the transcript it was supposed to stream' >&2
      exit 1
    fi
    # The refusal configured nothing, which is also the state the blocks below
    # start from.
    test ! -e "$XDG_CONFIG_HOME/babel/storage.json"
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"

    # provision names both targets, so a mistyped one cannot be mistaken for a
    # missing feature.
    ! atyrode provision nonsense 2>"$TMPDIR/provision-usage.err"
    grep -qF 'provision expects git or babel' "$TMPDIR/provision-usage.err"

    # Babel's storage document present but no success stamp: the archive has
    # never run here. That is configured-but-not-working, so it is told, never
    # offered -- there is no yes/no in "your archive is broken", only a fix.
    mkdir -p "$XDG_CONFIG_HOME/babel"
    printf '%s\n' '{}' > "$XDG_CONFIG_HOME/babel/storage.json"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-new.err" ||
      { cat "$TMPDIR/apply-archive-new.err" >&2; exit 1; }
    grep -qF 'has never archived successfully' "$TMPDIR/apply-archive-new.err"
    grep -qF 'fix with: babel archive status (then: babel archive push)' \
      "$TMPDIR/apply-archive-new.err"
    ! grep -qF 'now?' "$TMPDIR/apply-archive-new.err"

    # A stamp older than the staleness window warns and still activates.
    mkdir -p "$XDG_STATE_HOME/babel"
    date -u -d '3 days ago' +%FT%TZ > "$XDG_STATE_HOME/babel/last-success"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-stale.err" ||
      { cat "$TMPDIR/apply-archive-stale.err" >&2; exit 1; }
    grep -qE 'the last successful babel archive was [0-9]' \
      "$TMPDIR/apply-archive-stale.err"
    grep -qF 'fix with: babel archive status' "$TMPDIR/apply-archive-stale.err"

    # A fresh stamp is silent.
    date -u +%FT%TZ > "$XDG_STATE_HOME/babel/last-success"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-fresh.err" ||
      { cat "$TMPDIR/apply-archive-fresh.err" >&2; exit 1; }
    ! grep -qF 'babel archive' "$TMPDIR/apply-archive-fresh.err"

    # The other provisioning surface apply notices: the signing key the global
    # Git config names is missing. Without a terminal that stays exactly the
    # reminder it has always been, and nothing is asked of a machine that
    # cannot answer.
    printf '[user]\n\tsigningKey = %s\n' "$HOME/.ssh/absent-signing-key.pub" \
      > "$HOME/.gitconfig"
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/git-identity-quiet.err" ||
      { cat "$TMPDIR/git-identity-quiet.err" >&2; exit 1; }
    grep -qF 'Git identity is not configured: Git identity incomplete: the configured signing key is missing' \
      "$TMPDIR/git-identity-quiet.err"
    grep -qF 'configure with: atyrode provision git' "$TMPDIR/git-identity-quiet.err"
    if grep -qF 'run atyrode provision git' "$TMPDIR/git-identity-quiet.err" &&
      grep -qF 'now?' "$TMPDIR/git-identity-quiet.err"; then
      echo 'a machine with no terminal was asked a question it cannot answer' >&2
      exit 1
    fi
    # With a terminal the reminder is followed by the offer to run the command
    # it names, and a refusal is recorded so it is not asked twice.
    git_decline="$(printf 'n\n' | _ATYRODE_TEST_TTY=1 \
      atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" ||
      { printf '%s\n' "$git_decline" >&2; exit 1; }
    printf '%s\n' "$git_decline" | grep -qF 'the configured signing key is missing'
    printf '%s\n' "$git_decline" | grep -qF 'run atyrode provision git for alex-x86_64-linux now?'
    printf '%s\n' "$git_decline" | grep -qF 'this machine will not be asked again'
    rm -f "$XDG_STATE_HOME/atyrode/provisioning-declined"
    # Accepting runs that command for real, in this terminal. It cannot succeed
    # here (provision git refuses without an ssh-agent), and the refusal has to
    # stay the provisioning command's own: an apply that already activated does
    # not fail because the follow-up it offered did.
    git_accept="$(printf 'y\n' | _ATYRODE_TEST_TTY=1 SSH_AUTH_SOCK= \
      atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" ||
      { printf '%s\n' "$git_accept" >&2; exit 1; }
    printf '%s\n' "$git_accept" | grep -qF 'no ssh-agent socket'
    printf '%s\n' "$git_accept" | grep -qF 'that did not complete; Git identity is still unconfigured'
    # The child said what is wrong. Naming the same argv as "retry" would send
    # the operator to collect the identical failure, so the surface command is
    # offered as the thing to run afterwards, and the reason stays the child's.
    printf '%s\n' "$git_accept" | grep -qF 'clear what it reported above, then: atyrode provision git'
    if printf '%s\n' "$git_accept" | grep -qF 'retry: atyrode provision git'; then
      echo 'a failed ceremony advised rerunning the command that just failed' >&2
      exit 1
    fi
    # Accepting spawns a whole second program, so the boundary is named: every
    # line after it belongs to that child, and it is the argv an operator
    # repeats to retry the ceremony on its own.
    printf '%s\n' "$git_accept" | grep -qE '^  \$ .*atyrode provision git$'
    rm -f "$HOME/.gitconfig"

    # A degraded surface whose remedy is itself a dialogue. The seeder asks the
    # questions rather than answering them, so apply runs it instead of quoting
    # it -- which is exactly what makes announcing it non-negotiable: the next
    # thing on this terminal is a prompt from another program, and an operator
    # must never be questioned by something they did not see start.
    {
      printf '#!${pkgs.runtimeShell}\n'
      printf 'case "$1" in\n'
      printf '  status) printf %s ;;\n' \
        "'"'{"drift":[{"key":"recap.enabled"},{"key":"extendedContext"}]}\n'"'"
      printf '  resolve) printf %s ;;\n' "'"'seeder: reviewing 2 kept settings\n'"'"
      printf 'esac\n'
    } > "$TMPDIR/bin/atyrode-omp-seed"
    chmod +x "$TMPDIR/bin/atyrode-omp-seed"
    # Decline what can be declined first, so the only surface still acting on
    # the next run is the degraded one under test.
    printf 'n\nn\nn\n' | _ATYRODE_TEST_TTY=1 \
      atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>&1 || true
    seed_out="$(_ATYRODE_TEST_TTY=1 atyrode apply --repo "$HOME/nix-dotfiles" 2>&1)" ||
      { printf '%s\n' "$seed_out" >&2; exit 1; }
    printf '%s\n' "$seed_out" | grep -qF 'omp-seed: 2 omp setting(s) kept over the repository defaults'
    printf '%s\n' "$seed_out" | grep -qE '^  \$ atyrode-omp-seed resolve$'
    # The dialogue's own output follows the line that named it, in that order.
    printf '%s\n' "$seed_out" | grep -qF 'seeder: reviewing 2 kept settings'
    test "$(printf '%s\n' "$seed_out" | grep -n 'atyrode-omp-seed resolve' | head -1 | cut -d: -f1)" \
      -lt "$(printf '%s\n' "$seed_out" | grep -n 'seeder: reviewing' | head -1 | cut -d: -f1)"
    rm -f "$TMPDIR/bin/atyrode-omp-seed" "$XDG_STATE_HOME/atyrode/provisioning-declined"

    printf '%s\n' sentinel > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    export ATYRODE_NH_FAIL=1
    if atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/nh-fail.err"; then
      echo 'failed activation unexpectedly succeeded' >&2
      exit 1
    fi
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    # nh builds before it switches, so a failure here usually never reached the
    # machine. Reporting it as a failed activation sent an operator to repair a
    # machine that was fine, and bootstrap then offered to reset its Nix.
    grep -qF 'nothing was activated: this machine is unchanged' "$TMPDIR/nh-fail.err" \
      || { echo "a failure that changed nothing must say so: $(cat "$TMPDIR/nh-fail.err")" >&2; exit 1; }
    ! grep -qF 'could not activate this machine' "$TMPDIR/nh-fail.err" \
      || { echo 'a build failure must not be reported as a failed activation' >&2; exit 1; }
    # The plan promised five steps and one of them failed; the other four must
    # not simply vanish from the terminal, which reads as though they ran.
    test "$(grep -cF 'not attempted' "$TMPDIR/nh-fail.err")" = 4 \
      || { echo "every unreached planned step owes a verdict: $(cat "$TMPDIR/nh-fail.err")" >&2; exit 1; }
    grep -qF 'Converge the account login shell' "$TMPDIR/nh-fail.err" \
      || { echo 'an abandoned step must be named, not just counted' >&2; exit 1; }
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
    if grep -F -- '--pty' "$TMPDIR/fake-systemd/run-args" >/dev/null; then
      echo 'a detached apply was handed a terminal it has no operator for' >&2
      exit 1
    fi
    jq -e '.live == false' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/metadata.json" >/dev/null
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

    # A worker that dies without publishing leaves its captured output as the
    # only account of how far the apply got. The waiting CLI must hand that
    # output to the operator instead of sending them to the journal for
    # evidence it is already holding.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    rm -f "$TMPDIR/nh-started"
    set +e
    ATYRODE_NH_DELAY=30 atyrode apply --repo "$HOME/nix-dotfiles" \
      >"$TMPDIR/killed-apply.out" 2>"$TMPDIR/killed-apply.err" &
    apply_caller="$!"
    for _ in $(seq 1 200); do
      [[ ! -e "$TMPDIR/nh-started" ]] || break
      sleep 0.05
    done
    set -e
    test -e "$TMPDIR/nh-started"
    worker_pid="$(cat "$TMPDIR/fake-systemd/atyrode-apply.service.pid")"
    kill -9 -"$worker_pid" 2>/dev/null || kill -9 "$worker_pid" 2>/dev/null || true
    wait "$apply_caller" 2>/dev/null || true
    killed_job="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    if [[ -e "$XDG_STATE_HOME/atyrode/apply-jobs/$killed_job/result.json" ]]; then
      echo 'killed worker unexpectedly published a result' >&2
      exit 1
    fi
    grep -qF 'stopped without publishing a result' "$TMPDIR/killed-apply.err"
    if ! grep -qF 'mutation boundary:' "$TMPDIR/killed-apply.out"; then
      echo 'CLI withheld the dead worker output it already had on disk' >&2
      cat "$TMPDIR/killed-apply.out" >&2
      exit 1
    fi

    # Activation restarts session infrastructure, so mid-apply the user bus
    # stops answering for a moment and a live worker reports the same status
    # as a dead one. The CLI must keep waiting for a job that is still running
    # rather than declare a successful apply lost.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    rm -f "$TMPDIR/nh-started"
    mkdir -p "$TMPDIR/fake-systemd"
    printf '20\n' > "$TMPDIR/fake-systemd/bus-unanswerable"
    set +e
    ATYRODE_NH_DELAY=3 atyrode apply --repo "$HOME/nix-dotfiles" \
      >"$TMPDIR/bus-apply.out" 2>"$TMPDIR/bus-apply.err"
    bus_apply_status="$?"
    set -e
    if [[ "$bus_apply_status" != 0 ]]; then
      echo "CLI abandoned a live apply job when the user bus could not answer (exit $bus_apply_status)" >&2
      cat "$TMPDIR/bus-apply.err" >&2
      exit 1
    fi
    # The poll rate is not a contract, so require only that the CLI actually
    # met an unanswerable bus and carried on: one refusal is what the old
    # code abandoned the job on.
    if [[ "$(cat "$TMPDIR/fake-systemd/bus-unanswerable")" -ge 20 ]]; then
      echo 'the unanswerable-bus window never opened; the scenario proves nothing' >&2
      exit 1
    fi
    bus_job="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    jq -e '.phase == "succeeded" and .exitCode == 0' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$bus_job/result.json" >/dev/null
    grep -qF 'detached activation completed' "$TMPDIR/bus-apply.out"
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

    wsl_apply="$(atyrode apply alex-x86_64-linux-wsl --repo "$HOME/nix-dotfiles" --json \
      2>"$TMPDIR/wsl-apply.err")"
    jq -e '.activation == "nixos-wsl" and .backend == "nh-os"' <<<"$wsl_apply" >/dev/null
    # NixOS and nix-darwin activate as root, and the backend elevates for that
    # itself. Unannounced, the password prompt arrives mid-build from inside
    # someone else's output, and reads as the dotfiles asking for root out of
    # nowhere -- so the step names whose prompt it is before it can appear.
    grep -qF 'so nh elevates: a sudo prompt below is its own' "$TMPDIR/wsl-apply.err"
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

    # The detached apply job must fail the same way as the synchronous path.
    # apply_config's command substitutions are unguarded because it assumes
    # errexit, and the worker's `set +e` was inherited by the subshell running
    # it: windows_plan's failure then became an empty string that reached
    # `jq --argjson` as a raw parse error, and the job still published success.
    # Asserting the absence of the second winget diagnostic pins the abort to
    # the first failure instead of some later one.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    set +e
    _ATYRODE_TEST_SYSTEMD_AVAILABLE=1 \
      ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      ATYRODE_WINGET="$TMPDIR/bin/missing-winget.exe" \
      atyrode apply alex-x86_64-linux-wsl --repo "$HOME/nix-dotfiles" \
      > "$TMPDIR/wsl-job.out" 2> "$TMPDIR/wsl-job.err"
    wsl_job_status="$?"
    set -e
    test "$wsl_job_status" = 69
    grep -qF 'winget.exe is unavailable through WSL interop' "$TMPDIR/wsl-job.out"
    if grep -qF 'invalid JSON text passed to --argjson' \
      "$TMPDIR/wsl-job.out" "$TMPDIR/wsl-job.err"; then
      echo 'apply leaked a raw jq parse error instead of its own diagnostic' >&2
      exit 1
    fi
    if grep -qF 'could not report its version' "$TMPDIR/wsl-job.out"; then
      echo 'apply continued past an unavailable winget.exe' >&2
      exit 1
    fi
    wsl_job_id="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    jq -e '.phase == "failed" and .exitCode == 69' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$wsl_job_id/result.json" >/dev/null

    # Production resolves winget.exe off PATH, and WSL appends the Windows
    # entries to the session PATH only - the systemd user manager never gets
    # them. The apply worker therefore has to be handed the submitter's PATH,
    # or every Windows reconciliation fails with an unavailable winget.exe on a
    # host where the interactive shell finds it fine.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    # The blocked-conflict scenario above left the stable Zen package present;
    # clear it so this scenario turns on interop reachability alone.
    rm -f "$WINGET_STATE/stable" "$WINGET_STATE/twilight"
    : > "$WINGET_LOG"
    set +e
    env -u ATYRODE_WINGET \
      _ATYRODE_TEST_SYSTEMD_AVAILABLE=1 \
      ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      atyrode apply alex-x86_64-linux-wsl --repo "$HOME/nix-dotfiles" \
      > "$TMPDIR/wsl-path.out" 2> "$TMPDIR/wsl-path.err"
    wsl_path_status="$?"
    set -e
    if grep -qF 'winget.exe is unavailable through WSL interop' "$TMPDIR/wsl-path.out"; then
      echo 'apply worker lost the interop PATH; winget.exe was unreachable' >&2
      exit 1
    fi
    if [[ "$wsl_path_status" != 0 ]]; then
      echo "apply through the job worker failed with $wsl_path_status" >&2
      exit 1
    fi
    grep -qF -- '--version' "$WINGET_LOG"

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
        substitutersExact:true,
        trustedKeysExact:true,
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
      and (.checks[] | select(.id == "nix-policy") | .expected.substituters) == [
        "https://cache.nixos.org/",
        "https://atyrode-nix-cache.cellar-c2.services.clever-cloud.com"
      ]
      and (.checks[] | select(.id == "nix-policy") | .expected.trustedPublicKeys | length) == 2
    ' <<< "$system_result" >/dev/null
    if grep -q 'super-secret' <<< "$system_result"; then
      echo 'system diagnostics exposed raw Nix configuration' >&2
      exit 1
    fi

    # A standalone Linux host whose daemon predates the fleet cache: trust and
    # signatures are right, only the cache lists lag. No Nix layer owns
    # /etc/nix/nix.conf there, so the remediation must be the exact privileged
    # line that enrols the daemon, not a pointer to a configuration nobody has.
    linux_stale_cache="$TMPDIR/linux-stale-cache.json"
    jq '.nix.substitutersExact = false | .nix.trustedKeysExact = false' "$linux_ready" > "$linux_stale_cache"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$linux_stale_cache"
    if atyrode doctor system alex-x86_64-linux-desktop --json > "$TMPDIR/linux-stale-cache.out"; then
      echo 'a daemon without the fleet cache unexpectedly passed diagnostics' >&2
      exit 1
    else
      test "$?" -eq 69
    fi
    jq -e '
      (.checks[] | select(.id == "nix-policy") | .code) == "nix-policy-drift"
      and (.checks[] | select(.id == "nix-policy") | .remediation
        | test("^the daemon does not list the fleet cache; enrol it with: printf .%s\\\\n. .extra-substituters = https://atyrode-nix-cache[^ ]*. .extra-trusted-public-keys = atyrode-cache-1:[^ ]*. \\| sudo tee -a /etc/nix/nix.conf >/dev/null && sudo systemctl restart nix-daemon$"))
    ' "$TMPDIR/linux-stale-cache.out" >/dev/null
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$linux_ready"

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
        substitutersExact:false,
        trustedKeysExact:false,
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
        substitutersExact:true,
        trustedKeysExact:true,
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

    # Diagnostics observe; only apply mutates. The scan used to cover the whole
    # file, which worked only while nothing in the CLI ever changed system
    # state. Apply converges the login shell now, so the rule is stated where it
    # actually applies: no probe and no doctor family may contain a mutating
    # command, whatever else the file does.
    awk '
      /^[a-z_]+\(\)/ {
        inside = ($0 ~ "^(probe_|doctor_|collect_provisioning_checks)")
      }
      inside { print }
    ' ${atyrodeSource} > "$TMPDIR/diagnostic-bodies.sh"
    test -s "$TMPDIR/diagnostic-bodies.sh"
    if grep -Eq 'brew bundle cleanup .*--(force|zap)|(^|[[:space:]])(sudo|chsh|usermod|freshclam)([[:space:]]|$)|adb[[:space:]]+devices' \
      "$TMPDIR/diagnostic-bodies.sh"; then
      echo 'doctor system contains a mutating system probe' >&2
      exit 1
    fi
    # And the converse, so the mutation cannot quietly reappear somewhere else:
    # chsh belongs to exactly one function, the one that owns the convergence.
    awk '
      /^[a-z_]+\(\)/ { inside = ($0 ~ "^converge_login_shell") }
      !inside && /(^|[[:space:]])chsh([[:space:]]|$)/ { hit = 1 }
      END { exit hit ? 1 : 0 }
    ' ${atyrodeSource} || {
      echo 'chsh appears outside converge_login_shell, which owns login-shell state' >&2
      exit 1
    }
    # The Homebrew drift probe is a READ-ONLY comparison against the immutable,
    # store-owned Brewfile. The scan above forbids a mutating spelling
    # structurally; this pins the brew invocation the probe ACTUALLY makes. A
    # darwin fixture with no .homebrew key falls through to the live branch, so
    # the PATH stub below is the brew the probe really runs — and a hostile
    # HOMEBREW_BUNDLE_FILE / HOMEBREW_NO_AUTO_UPDATE in the caller's environment
    # must not reach it.
    cat > "$TMPDIR/bin/brew" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/brew-args"
    printf 'bundle-file=%s auto-update=%s\n' \
      "''${HOMEBREW_BUNDLE_FILE-unset}" "''${HOMEBREW_NO_AUTO_UPDATE-unset}" \
      >> "$TMPDIR/brew-env"
    if IFS= read -r stdin_line; then
      printf 'stdin=%s\n' "$stdin_line" >> "$TMPDIR/brew-stdin"
    else
      printf 'stdin=closed\n' >> "$TMPDIR/brew-stdin"
    fi
    EOF
    chmod +x "$TMPDIR/bin/brew"
    darwin_live_brew="$TMPDIR/darwin-live-brew.json"
    jq 'del(.homebrew)' "$darwin_ready" > "$darwin_live_brew"
    rm -f "$TMPDIR/brew-args" "$TMPDIR/brew-env" "$TMPDIR/brew-stdin"
    live_brew_result="$(HOMEBREW_BUNDLE_FILE="$TMPDIR/caller-Brewfile" \
      HOMEBREW_NO_AUTO_UPDATE=0 \
      _ATYRODE_TEST_SYSTEM=aarch64-darwin _ATYRODE_TEST_USER=alex \
      _ATYRODE_TEST_SYSTEM_FIXTURE="$darwin_live_brew" \
      atyrode doctor system alex-aarch64-darwin --json <<<'PROMPT-ANSWER')"
    jq -e '.checks[] | select(.id == "homebrew-drift")
      | .status == "ok" and .actual.available and (.actual.drift | not)
        and (.actual.probeFailed | not)' <<<"$live_brew_result" >/dev/null \
      || { echo "the live Homebrew probe verdict is wrong: $live_brew_result" >&2; exit 1; }
    grep -qxE 'bundle check --no-upgrade --file /nix/store/[^ ]+-atyrode-Brewfile' \
      "$TMPDIR/brew-args" \
      || { echo "drift probe must check against the immutable Brewfile: $(cat "$TMPDIR/brew-args")" >&2; exit 1; }
    grep -qxE 'bundle cleanup --file /nix/store/[^ ]+-atyrode-Brewfile' \
      "$TMPDIR/brew-args" \
      || { echo "drift probe must run a flagless bundle cleanup: $(cat "$TMPDIR/brew-args")" >&2; exit 1; }
    test "$(wc -l < "$TMPDIR/brew-args")" = 2 \
      || { echo "drift probe ran unexpected brew commands: $(cat "$TMPDIR/brew-args")" >&2; exit 1; }
    test "$(LC_ALL=C sort -u "$TMPDIR/brew-env")" = 'bundle-file=unset auto-update=1' \
      || { echo "drift probe must drop a caller Brewfile and disable auto-update: $(cat "$TMPDIR/brew-env")" >&2; exit 1; }
    test "$(LC_ALL=C sort -u "$TMPDIR/brew-stdin")" = stdin=closed \
      || { echo "drift probe must never read the caller's stdin: $(cat "$TMPDIR/brew-stdin")" >&2; exit 1; }
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
