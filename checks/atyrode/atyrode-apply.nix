{
  atyrode,
  pkgs,
  productionAtyrode,
  productionHost,
}:

let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
  developmentAtyrode = atyrode.override { revision = "unknown"; };
  launcherAtyrode = atyrode.override { revision = "1111111111111111111111111111111111111111"; };
  targetPolicy = pkgs.writeText "candidate-personal-policy" ''
    # Candidate personal policy

    This fixture deliberately differs from the launcher's embedded policy.
  '';
  targetAtyrode =
    (atyrode.override { revision = "feedfacefeedfacefeedfacefeedfacefeedface"; }).overrideAttrs
      (old: {
        installPhase = builtins.replaceStrings [ "${../../modules/home/agents/AGENTS.md}" ] [
          "${targetPolicy}"
        ] old.installPhase;
      });
  publishedKeyAtyrode = atyrode.override {
    sopsDirectory = pkgs.writeTextDir "secrets/fixture-nixos-age.key/secret" "{}";
  };
  serviceGeneration =
    name: service: command:
    pkgs.runCommand "${name}-home-manager-generation" { } ''
      mkdir -p "$out/home-files/.config/systemd/user"
      printf '[Unit]\nDescription=Fixture 1.0\n[Service]\nExecStart=%s\n' '${command}' \
        > "$out/home-files/.config/systemd/user/${service}.service"
    '';
  ownerOld =
    serviceGeneration "owner-old" "manifold-agent"
      "/nix/store/fixture-manifold-1.0/bin/agent --old";
  ownerNew =
    serviceGeneration "owner-new" "manifold-agent"
      "/nix/store/fixture-manifold-1.0/bin/agent --new";
  scopedOld = serviceGeneration "scoped-old" "caddy" "/nix/store/fixture-caddy-1.0/bin/caddy --old";
  scopedNew = serviceGeneration "scoped-new" "caddy" "/nix/store/fixture-caddy-1.0/bin/caddy --new";
  unknownCandidate = pkgs.runCommand "fixture-unknown-generation" { } ''mkdir "$out"'';
  contextCandidate = pkgs.runCommand "context-candidate-home-manager-generation" { } ''
    mkdir -p "$out/home-files/.config/systemd/user"
    ln -s ${targetAtyrode} "$out/home-path"
  '';
in
pkgs.runCommand "check-atyrode-apply"
  {
    nativeBuildInputs = [
      developmentAtyrode
      pkgs.gh
      pkgs.jq
      pkgs.age
      pkgs.sops
    ];
  }
  ''
    ${fixtures.base}
    ${fixtures.gitNh}
    ${fixtures.identity}
    ${pkgs.python3.interpreter} ${./declared-inputs.py} ${../../pkgs/atyrode/inputs}
    ${pkgs.python3.interpreter} ${./apply-jobs.py} ${../../pkgs/atyrode/lib} ${pkgs.runtimeShell}
    ${pkgs.python3.interpreter} ${./wsl-path.py} ${../../pkgs/atyrode/wsl-path}

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
    if [[ -n "''${ATYRODE_TEST_MANAGER_HOST:-}" ]]; then
      export ATYRODE_HOST="$ATYRODE_TEST_MANAGER_HOST"
    fi
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
      *'show --property=LoadState,ActiveState -- manifold-agent.service')
        printf 'LoadState=loaded\nActiveState=%s\n' "''${ATYRODE_TEST_OWNER_ACTIVE:-active}" ;;
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
        for pid_file in "$TMPDIR/fake-systemd"/$unit.pid; do
          [[ -r "$pid_file" ]] || continue
          if kill -0 "$(cat "$pid_file")" 2>/dev/null; then exit 0; fi
        done
        exit 4
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
    # nh/nix-env against the live store. (Regression guard for a near-miss where
    # the production binary was run with stub overrides during development.)
    for prod_cmd in clean apply rollback; do
      set +e
      env -u ATYRODE_NH -u ATYRODE_GIT -u ATYRODE_GEN_PROFILE \
        ATYRODE_NIX_ENV=/bin/true \
        ${productionAtyrode}/bin/atyrode "$prod_cmd" --yes \
        > /dev/null 2> "$TMPDIR/prod-guard.err"
      prod_guard_status="$?"
      set -e
      test "$prod_guard_status" = 64 \
        || { echo "production $prod_cmd must refuse a tool override (exit $prod_guard_status): $(cat "$TMPDIR/prod-guard.err")" >&2; exit 1; }
      grep -qF ATYRODE_NIX_ENV "$TMPDIR/prod-guard.err" \
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
      grep -qF "$override" "$TMPDIR/prod-apply-manager-guard.err"
    done
    # The guard is scoped to mutating verbs: a read-only command with the same
    # override present still runs (production simply ignores the var there).
    env ATYRODE_NIX_ENV=/bin/true ${productionAtyrode}/bin/atyrode --help >/dev/null 2>&1 \
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
      ( unset ATYRODE_GIT ATYRODE_NH ATYRODE_NIX_ENV ATYRODE_GEN_PROFILE
        export "$seam_var=$TMPDIR/seam/$seam_tool"
        exec ${productionAtyrode}/bin/atyrode apply --plan
      ) > /dev/null 2> "$TMPDIR/prod-seam.err"
      seam_status="$?"
      set -e
      test "$seam_status" = 64 \
        || { echo "production apply must refuse $seam_var (exit $seam_status): $(cat "$TMPDIR/prod-seam.err")" >&2; exit 1; }
      grep -qF "$seam_var" "$TMPDIR/prod-seam.err" \
        || { echo "production refusal must name $seam_var" >&2; exit 1; }
      test ! -e "$TMPDIR/seam/$seam_tool.used" \
        || { echo "a production build must never reach the $seam_var stub" >&2; exit 1; }
    done

    atyrode </dev/null | grep -qF 'Usage:'

    atyrode capabilities list --json | jq -e '
      (map(.name) | index("base") and index("development"))
      and all(.[]; .description | length > 0)
      and (.[] | select(.name == "base") | .active)
      and ((.[] | select(.name == "desktop") | .active) | not)
    ' >/dev/null
    atyrode capabilities show development-x86_64-linux --json | jq -e '
      .host == "development-x86_64-linux"
      and (.description | length > 0)
      and (.capabilities | map(.name) | index("agent-tools"))
      and all(.capabilities[]; .description | length > 0)
    ' >/dev/null

    # On a machine whose identity is ambiguous the list degrades to
    # unmarked instead of dying.
    mv "$XDG_CONFIG_HOME/atyrode/host.json" "$TMPDIR/host.json"
    atyrode capabilities list --json | jq -e 'all(.[]; .active | not)' >/dev/null
    mv "$TMPDIR/host.json" "$XDG_CONFIG_HOME/atyrode/host.json"
    atyrode doctor host --json | jq -e '.ok and .registered.id == "development-x86_64-linux"' >/dev/null
    tools="$(atyrode doctor tools --json || true)"
    jq -e '
      any(.[]; .name == "OMP"
        and .capability == "agent-tools"
        and (.launchModes | index("untrusted"))
        and (.versionOwner | length > 0))
      and all(.[]; .status != "missing" or (.remediation | contains("do not install globally")))
    ' <<< "$tools" >/dev/null

    # Generated identities in files and login environments can outlive a
    # rename. Only an explicit argument may require a retired identity;
    # recovering an inherited value requires a current record or exact host.
    printf '%s\n' '{"id":"alex-aarch64-darwin"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
    env _ATYRODE_TEST_SYSTEM=aarch64-darwin _ATYRODE_TEST_USER=alex \
      _ATYRODE_TEST_HOSTNAME=alex-aarch64-darwin \
      atyrode apply --repo "$HOME/nix-dotfiles" --plan --json |
      jq -e '.host == "macbook" and .backend == "nh-darwin"' >/dev/null
    printf '%s\n' '{"id":"alex-x86_64-linux-wsl"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
    env _ATYRODE_TEST_SYSTEM=x86_64-linux _ATYRODE_TEST_USER=alex \
      _ATYRODE_TEST_HOSTNAME=wsl \
      atyrode context --json |
      jq -e '.host.id == "wsl"' >/dev/null
    env ATYRODE_HOST=alex-x86_64-linux-wsl \
      _ATYRODE_TEST_SYSTEM=x86_64-linux _ATYRODE_TEST_USER=alex \
      _ATYRODE_TEST_HOSTNAME=wsl atyrode context --json |
      jq -e '.host.id == "wsl"' >/dev/null
    set +e
    env ATYRODE_HOST=retired-host _ATYRODE_TEST_HOSTNAME=unregistered \
      atyrode context --json > /dev/null 2> "$TMPDIR/ambiguous-inherited-host.err"
    inherited_status="$?"
    set -e
    test "$inherited_status" = 65
    set +e
    atyrode apply alex-aarch64-darwin --repo "$HOME/nix-dotfiles" --plan \
      > /dev/null 2> "$TMPDIR/unknown-host.err"
    unknown_host_status="$?"
    set -e
    test "$unknown_host_status" = 65
    grep -qF alex-aarch64-darwin "$TMPDIR/unknown-host.err"

    # Naming an unregistered former hostname is enough to distinguish a
    # deliberate rename from applying one registered machine over another.
    env _ATYRODE_TEST_HOSTNAME=tyrode-dev-01 \
      atyrode apply dev-01 --repo "$HOME/nix-dotfiles" --plan --json \
      > "$TMPDIR/rename-plan.json" 2> "$TMPDIR/rename-plan.err"
    jq -e '.host == "dev-01" and .backend == "nh-os"' "$TMPDIR/rename-plan.json" >/dev/null

    printf '%s\n' '{"id":"dev-01"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
    set +e
    env _ATYRODE_TEST_HOSTNAME=tyrode-dev-01 \
      atyrode apply --repo "$HOME/nix-dotfiles" --plan \
      > /dev/null 2> "$TMPDIR/implicit-rename.err"
    implicit_rename_status="$?"
    set -e
    test "$implicit_rename_status" = 65
    grep -qF 'atyrode apply dev-01' "$TMPDIR/implicit-rename.err"

    set +e
    env _ATYRODE_TEST_HOSTNAME=wsl \
      atyrode apply dev-01 --repo "$HOME/nix-dotfiles" --plan \
      > /dev/null 2> "$TMPDIR/cross-host.err"
    cross_host_status="$?"
    set -e
    test "$cross_host_status" = 65
    grep -qF 'apply wsl' "$TMPDIR/cross-host.err"
    printf '%s\n' '{"id":"development-x86_64-linux"}' > "$XDG_CONFIG_HOME/atyrode/host.json"

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
    PATH="$stripped" command -v nix-locate >/dev/null && false
    # Non-zero because the stripped PATH leaves other declared tools missing;
    # the assertion is about the one that must be found regardless.
    env PATH="$stripped" "$(command -v atyrode)" doctor tools --json > "$TMPDIR/adopted.json" || true
    jq -e --arg profile "$HOME/.nix-profile/bin/nix-locate" '
      any(.[]; .name == "nix-index" and .status == "ok" and .path == $profile)
    ' "$TMPDIR/adopted.json" >/dev/null

    atyrode apply --repo "$HOME/nix-dotfiles" --plan --json | jq -e '
      .host == "development-x86_64-linux"
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
    test ! -e "$TMPDIR/nh-args"
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"

    # The operator identity (ADR 0008 step 3, amended: one key per device):
    # every fixed host is an operator device holding its own key, a member of
    # the admins group every value is encrypted to. Off a Mac the key comes
    # from age-keygen, stubbed here for a deterministic recipient -- the one
    # the fixture sops tree registers for the device -- and the private line
    # it writes is a sentinel no output may ever carry.
    cat > "$TMPDIR/bin/age-keygen" <<'EOF'
    #!${pkgs.runtimeShell}
    minted_recipient=age1fixturedevice00000000000000000000000000000000000000000000000
    case "''${1:-}" in
      -o)
        umask 077
        printf '# created: fixture\n# public key: %s\nAGE-SECRET-KEY-1FIXTUREONLY\n' \
          "$minted_recipient" > "$2"
        printf 'Public key: %s\n' "$minted_recipient" >&2
        ;;
      *) exit 64 ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/age-keygen"
    export ATYRODE_AGE_KEYGEN="$TMPDIR/bin/age-keygen"
    device_recipient=age1fixturedevice00000000000000000000000000000000000000000000000
    operator_key="$XDG_CONFIG_HOME/sops/age/keys.txt"
    operator_probe() { # host status code
      ATYRODE_HOST="$1" atyrode doctor provisioning --json |
        jq -e --arg status "$2" --arg code "$3" '
          .surfaces[] | select(.id == "operator-identity")
          | .status == $status and (.code // "") == $code
            and .command == "atyrode operator init" and .declinable == false
            and (.implies | contains("never leaves the device"))
        ' >/dev/null
    }
    # No key yet: show says so and exits with a finding, and the probe names
    # the ceremony. A portable profile is not a device and refuses outright.
    test ! -e "$operator_key"
    operator_probe fixture-nixos incomplete not-configured
    set +e
    ATYRODE_HOST=fixture-nixos atyrode operator show > "$TMPDIR/operator-none.out" 2> "$TMPDIR/operator-none.err"
    operator_status="$?"
    set -e
    test "$operator_status" = 69
    test ! -s "$TMPDIR/operator-none.out"
    grep -qF 'atyrode operator init' "$TMPDIR/operator-none.err"
    set +e
    ATYRODE_HOST=development-x86_64-linux atyrode operator show > "$TMPDIR/operator-portable.out" 2> "$TMPDIR/operator-portable.err"
    operator_status="$?"
    set -e
    test "$operator_status" = 65
    operator_probe development-x86_64-linux not-applicable portable-profile
    # init on a Linux device announces the one command, lands the key at the
    # modes a secret demands, and -- the fixture sops tree already registering
    # the recipient it minted in the group -- the probe reports the device
    # registered.
    ATYRODE_HOST=fixture-nixos atyrode operator init > "$TMPDIR/operator-init.out" 2> "$TMPDIR/operator-init.err"
    grep -qE "^\\$ $TMPDIR/bin/age-keygen -o $operator_key\$" "$TMPDIR/operator-init.err"
    test ! -s "$TMPDIR/operator-init.out"
    test -f "$operator_key"
    test "$(stat -c %a "$operator_key")" = 600
    test "$(stat -c %a "''${operator_key%/*}")" = 700
    grep -qF 'AGE-SECRET-KEY-1FIXTUREONLY' "$operator_key"
    operator_probe fixture-nixos ok ""
    ATYRODE_HOST=fixture-nixos atyrode operator show > "$TMPDIR/operator-show.out" 2> "$TMPDIR/operator-show.err"
    test "$(cat "$TMPDIR/operator-show.out")" = "$device_recipient"
    # A second init keeps the key: files may already be encrypted to it, so
    # no keygen is announced and the private line is the one first written.
    ATYRODE_HOST=fixture-nixos atyrode operator init > "$TMPDIR/operator-again.out" 2> "$TMPDIR/operator-again.err"
    grep -qF 'age-keygen' "$TMPDIR/operator-again.err" && false
    test ! -s "$TMPDIR/operator-again.out"
    grep -qF 'AGE-SECRET-KEY-1FIXTUREONLY' "$operator_key"
    # A recipient clan does not register: the probe and the verb print
    # exactly the two commands that register it, in order.
    sed -i 's/^# public key: .*/# public key: age1unregistereddevice000000000000000000000000000000000000000000/' "$operator_key"
    operator_probe fixture-nixos degraded not-registered
    ATYRODE_HOST=fixture-nixos atyrode doctor provisioning --json | jq -e '
      .surfaces[] | select(.id == "operator-identity")
      | (.summary | contains("sops/users/alex-fixture-nixos/key.json in group admins"))
        and .remediation == "in any checkout, run: clan secrets users add alex-fixture-nixos age1unregistereddevice000000000000000000000000000000000000000000 && clan secrets groups add-user admins alex-fixture-nixos"' >/dev/null
    ATYRODE_HOST=fixture-nixos atyrode operator show > "$TMPDIR/operator-unregistered.out" 2> "$TMPDIR/operator-unregistered.err"
    grep -qE '^  \$ clan secrets users add alex-fixture-nixos age1unregistereddevice000000000000000000000000000000000000000000$' \
      "$TMPDIR/operator-unregistered.err"
    grep -qE '^  \$ clan secrets groups add-user admins alex-fixture-nixos$' "$TMPDIR/operator-unregistered.err"
    # A file without a recipient line is not one this ceremony wrote: it is
    # neither overwritten nor mistaken for a key, and the way out is said
    # rather than taken.
    printf 'not a key file\n' > "$operator_key"
    operator_probe fixture-nixos incomplete not-configured
    set +e
    ATYRODE_HOST=fixture-nixos atyrode operator init > "$TMPDIR/operator-foreign.out" 2> "$TMPDIR/operator-foreign.err"
    operator_status="$?"
    set -e
    test "$operator_status" = 65
    test "$(cat "$operator_key")" = 'not a key file'
    grep -qF 'age-keygen' "$TMPDIR/operator-foreign.err" && false
    rm -f "$operator_key"
    # On a Mac the key is minted by age-plugin-se inside the Secure Enclave;
    # the verb and its probe gate on the registry's system, so a Linux
    # sandbox walks the Mac's ceremony by naming the host.
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
    enclave_recipient=age1se1fixtureoperator00000000000000000000000000000000000000000000
    operator_probe macbook incomplete not-configured
    ATYRODE_HOST=macbook atyrode operator init > "$TMPDIR/operator-mac.out" 2> "$TMPDIR/operator-mac.err"
    grep -qE "^\\$ .*age-plugin-se keygen --access-control=any-biometry-or-passcode -o $operator_key\$" "$TMPDIR/operator-mac.err"
    test "$(cat "$TMPDIR/operator-mac.out")" = "Public key: $enclave_recipient"
    grep -qF 'AGE-PLUGIN-SE-1FIXTUREONLY' "$operator_key"
    operator_probe macbook ok ""
    # Neither identity line ever reaches a terminal, in any of the runs above.
    for operator_output in "$TMPDIR"/operator-*.out "$TMPDIR"/operator-*.err; do
      grep -qF 'AGE-PLUGIN-SE-1' "$operator_output" && false
      grep -qF 'AGE-SECRET-KEY' "$operator_output" && false
    done

    # The machine key (ADR 0008 step 3, amended: clan's default): the age key
    # a machine decrypts its vars with is minted into the repository by an
    # operator device and placed on the machine by apply. The probe names
    # which of the two steps is owed; a host clan does not build has neither.
    machine_key_probe() { # host status code [cli]
      ATYRODE_HOST="$1" "''${4:-atyrode}" doctor provisioning --json |
        jq -e --arg status "$2" --arg code "$3" '
          .surfaces[] | select(.id == "machine-key")
          | .status == $status and (.code // "") == $code
        ' >/dev/null
    }
    machine_key_probe development-x86_64-linux not-applicable portable-profile
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/machine-key-apply.err" ||
      { cat "$TMPDIR/machine-key-apply.err" >&2; exit 1; }
    machine_key_probe fixture-nixos incomplete not-configured
    # Minting needs a registered operator key on this device; without one the
    # ceremony says which device can, rather than handing over clan's refusal.
    set +e
    ATYRODE_HOST=fixture-nixos atyrode provision machine-key --repo "$HOME/nix-dotfiles" > "$TMPDIR/machine-key-nodevice.out" 2> "$TMPDIR/machine-key-nodevice.err"
    machine_key_status="$?"
    set -e
    test "$machine_key_status" = 69
    grep -qF 'clan vars generate fixture-nixos' "$TMPDIR/machine-key-nodevice.err"
    # A conflicting conventional checkout must not replace the published source.
    machine_root="$TMPDIR/machine"
    export _ATYRODE_TEST_IDENTITY_ROOT="$machine_root"
    machine_key="$machine_root/var/lib/sops-nix/key.txt"
    mkdir -p "$HOME/nix-dotfiles/sops/secrets/fixture-nixos-age.key"
    printf '{"data":"ENC[AES256_GCM,fixture]","sops":{"age":[]}}\n' > "$HOME/nix-dotfiles/sops/secrets/fixture-nixos-age.key/secret"
    machine_key_probe fixture-nixos incomplete not-configured
    machine_key_probe fixture-nixos degraded not-placed ${publishedKeyAtyrode}/bin/atyrode
    # Removing the conventional checkout cannot hide a published key either.
    mv "$HOME/nix-dotfiles" "$HOME/conventional-checkout-aside"
    machine_key_probe fixture-nixos degraded not-placed ${publishedKeyAtyrode}/bin/atyrode
    mv "$HOME/conventional-checkout-aside" "$HOME/nix-dotfiles"
    mkdir -p "''${machine_key%/*}"
    printf 'AGE-SECRET-KEY-1PLACED\n' > "$machine_key"
    machine_key_probe fixture-nixos ok ""
    # A cold sudo credential cache must not hide a visible root-only key, and
    # a denied directory traversal is unknown state, not a missing key.
    (
      source ${../../pkgs/atyrode/lib/apply.sh}
      test_hooks=0
      machine_key_file() { printf '%s\n' "$machine_key"; }
      sudo() { return 1; }
      machine_key_placed
    )
    chmod 000 "''${machine_key%/*}"
    machine_key_probe fixture-nixos degraded inspection-unavailable
    chmod 700 "''${machine_key%/*}"
    # Machine state wins over a stale conventional checkout. A remote apply
    # may have placed the published key while ~/nix-dotfiles still predates it;
    # that must not offer to mint a key which already exists.
    rm -rf "$HOME/nix-dotfiles/sops/secrets/fixture-nixos-age.key"
    machine_key_probe fixture-nixos ok ""
    rm -rf "$machine_root" "$HOME/nix-dotfiles/sops/secrets/fixture-nixos-age.key"
    unset _ATYRODE_TEST_IDENTITY_ROOT
    # This sandbox is itself a registered device from here on, as a real
    # operator machine would be after its first apply, so the clan scenarios
    # below find a key where they expect one.
    printf '# created: fixture\n# public key: %s\nAGE-SECRET-KEY-1DEVICEONLY\n' "$device_recipient" > "$operator_key"
    set +e
    ATYRODE_HOST=fixture-nixos atyrode provision machine-key \
      >"$TMPDIR/machine-key-source.out" 2>"$TMPDIR/machine-key-source.err"
    machine_key_status="$?"
    set -e
    test "$machine_key_status" = 64

    LC_CTYPE=UTF-8 atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-success.err" ||
      { cat "$TMPDIR/apply-success.err" >&2; exit 1; }
    # A successful apply on this portable fixture has nothing to arm: its
    # storage document is a clan var generated only for a fleet machine. The
    # arm branch is driven with a placed document further down.
    # No question is asked where nothing can answer it.
    grep -qF 'now?' "$TMPDIR/apply-success.err" && false
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = development-x86_64-linux
    test -z "$(find "$XDG_STATE_HOME/atyrode" -name '.dotfiles-config.*' -print -quit)"
    test "$(cat "$TMPDIR/nh-locale")" = C.UTF-8

    # A sandbox can neither hold nor acquire a real Clever Cloud session, and
    # explicit context diagnostics below report clever's session state, so a
    # stub keeps its own: `profile` succeeds once `login` has run.
    mkdir -p "$TMPDIR/sessionbin"
    {
      printf '#!%s\n' "${pkgs.runtimeShell}"
      printf 'case "$1" in\n'
      printf '  profile) echo clever >> "$TMPDIR/context-auth-probes"; test -e %s ;;\n' "$TMPDIR/clever-session"
      printf '  login) touch %s ;;\n' "$TMPDIR/clever-session"
      printf '  *) exit 1 ;;\n'
      printf 'esac\n'
    } > "$TMPDIR/sessionbin/clever"
    chmod +x "$TMPDIR/sessionbin/clever"
    touch "$TMPDIR/clever-session"
    export ATYRODE_CLEVER="$TMPDIR/sessionbin/clever"
    cat > "$TMPDIR/sessionbin/gh" <<'EOF'
    #!${pkgs.runtimeShell}
    echo gh >> "$TMPDIR/context-auth-probes"
    exit 1
    EOF
    chmod +x "$TMPDIR/sessionbin/gh"

    # ... and a home-manager apply writes nothing this user could not write, so
    # it must not warn about a password prompt that will never arrive.
    if grep -qF 'nh elevates' "$TMPDIR/apply-success.err"; then
      echo 'a home-manager apply warned about an elevation it never performs' >&2
      exit 1
    fi

    # Apply writes a regular, atomic policy snapshot, not diagnostic inventory.
    context_file="$XDG_CONFIG_HOME/agents/AGENTS.md"
    grep -qE '^  \$ atyrode context render$' "$TMPDIR/apply-success.err"
    test -f "$context_file"
    test ! -L "$context_file"
    test "$(stat -c %a "$context_file")" = 644
    test -z "$(find "$XDG_CONFIG_HOME/agents" -name '.AGENTS.md.*' -print -quit)"
    {
      cat ${../../modules/home/agents/AGENTS.md}
      printf '\n'
    } > "$TMPDIR/context-policy"
    sed '/^Generated at /d' "$context_file" | diff "$TMPDIR/context-policy" -
    # A copied closure renders its own policy and revision, not the invoking
    # CLI's or an unrelated global profile's. The final verdict has that same
    # owner even when the development launcher has different policy bytes.
    atyrode apply development-x86_64-linux --candidate ${contextCandidate} \
      > "$TMPDIR/candidate-context.out" 2> "$TMPDIR/candidate-context.err"
    grep -qF 'revision feedfacefeedfacefeedfacefeedfacefeedface by' "$context_file"
    { cat ${targetPolicy}; printf '\n'; } > "$TMPDIR/candidate-context-policy"
    sed '/^Generated at /d' "$context_file" | diff "$TMPDIR/candidate-context-policy" -
    if grep -qE 'remaining.*agent-context|context-stale' "$TMPDIR/candidate-context.err"; then
      echo 'candidate-owned context was judged against the launcher policy' >&2
      exit 1
    fi
    # A published launcher with an explicit dirty checkout does not hand off
    # the whole apply. Its built candidate must still own the final context.
    cat > "$TMPDIR/seam/dirty-git" <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      *diff\ --quiet*) exit 1 ;;
      *) exec "$TMPDIR/bin/git" "$@" ;;
    esac
    EOF
    chmod +x "$TMPDIR/seam/dirty-git"
    ATYRODE_GIT="$TMPDIR/seam/dirty-git" ATYRODE_TEST_CANDIDATE=${contextCandidate} \
      ${launcherAtyrode}/bin/atyrode apply --repo "$HOME/nix-dotfiles" --json \
      > "$TMPDIR/dirty-context.out" 2> "$TMPDIR/dirty-context.err"
    jq -e '.source == "local" and .dirty == true' "$TMPDIR/dirty-context.out" >/dev/null
    sed '/^Generated at /d' "$context_file" | diff "$TMPDIR/candidate-context-policy" -
    if grep -qE 'remaining.*agent-context|context-stale' "$TMPDIR/dirty-context.err"; then
      echo 'dirty apply left a false context blocker' >&2
      exit 1
    fi
    rm "$TMPDIR/seam/dirty-git"
    # Rendering must not acquire inventory, even on an unregistered host with
    # an unreadable diagnostic fixture and provider credentials in the process.
    # The existing command overrides also observe calls whose failures a
    # renderer might otherwise swallow. No production seam is added.
    planted_gh_token="ghp_$(printf 'FIXTURE%.0s' 1 2 3 4 5)"
    : > "$TMPDIR/context-auth-probes"
    PATH="$TMPDIR/sessionbin:$PATH" GH_TOKEN="$planted_gh_token" \
      ATYRODE_HOST=unregistered-context-host \
      _ATYRODE_TEST_SYSTEM_FIXTURE="$TMPDIR/context-missing-fixture" \
      atyrode context render 2>"$TMPDIR/context-render.err"
    test ! -s "$TMPDIR/context-auth-probes"
    # A valid host must not cause otherwise optional inventory probes either.
    PATH="$TMPDIR/sessionbin:$PATH" GH_TOKEN="$planted_gh_token" \
      atyrode context render 2>"$TMPDIR/context-render.err"
    test ! -s "$TMPDIR/context-auth-probes"
    sed '/^Generated at /d' "$context_file" | diff "$TMPDIR/context-policy" -
    grep -qF 'ghp_FIXTURE' "$context_file" && false
    cp "$context_file" "$TMPDIR/context-before-show"
    PATH="$TMPDIR/sessionbin:$PATH" atyrode context show > "$TMPDIR/context-show"
    sed '/^## This machine$/,$d' "$TMPDIR/context-show" |
      diff "$TMPDIR/context-policy" -
    grep -qF 'development-x86_64-linux' "$TMPDIR/context-show"
    test -s "$TMPDIR/context-auth-probes"
    diff "$context_file" "$TMPDIR/context-before-show"
    PATH="$TMPDIR/sessionbin:$PATH" atyrode context |
      sed '/^Generated at /d' > "$TMPDIR/context-default"
    sed '/^Generated at /d' "$TMPDIR/context-show" |
      diff "$TMPDIR/context-default" -
    PATH="$TMPDIR/sessionbin:$PATH" atyrode context --json > "$TMPDIR/context-show.json"
    jq -e '
      .schemaVersion == 1
      and .command == "context"
      and .target == (env.XDG_CONFIG_HOME + "/agents/AGENTS.md")
      and .revision == "unknown"
      and .host.id == "development-x86_64-linux"
      and (.fleet | map(.id) | index("macbook") != null)
      and (.fleet | map(.id) | index("development-x86_64-linux") == null)
      and .authentication.gh.authenticated == false
      and .authentication.gh.acquire == "gh auth login"
      and .authentication.clever.authenticated == true
      and (.authentication | has("bitwarden") | not)
      and (.secrets.readable | length) == 0
      and .fleetCache.substituter == "https://atyrode-nix-cache.cellar-c2.services.clever-cloud.com"
      and .fleetCache.trusted == false
      and .cloneRoot == null
      and .dotfilesCheckout == null
      and (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    ' "$TMPDIR/context-show.json" >/dev/null
    # The fixture has a conventional checkout; diagnostics must not infer it.
    test -d "$HOME/nix-dotfiles/.git"
    diff "$context_file" "$TMPDIR/context-before-show"
    atyrode context render --json >/dev/null 2>&1 && false
    atyrode context render show >/dev/null 2>&1 && false

    # Refusals propagate through the public command without announcing a write
    # or replacing the old document. Apply must also retain the failed step.
    mv "$context_file" "$TMPDIR/context-link-target"
    cp "$TMPDIR/context-link-target" "$TMPDIR/context-preserved"
    ln -s "$TMPDIR/context-link-target" "$context_file"
    set +e
    atyrode context render >"$TMPDIR/context-refused.out" 2>"$TMPDIR/context-refused.err"
    refused_status="$?"
    atyrode apply --repo "$HOME/nix-dotfiles" \
      >"$TMPDIR/context-refused-apply.out" 2>"$TMPDIR/context-refused-apply.err"
    refused_apply_status="$?"
    set -e
    test "$refused_status" = 65
    test "$refused_apply_status" = 69
    test -L "$context_file"
    diff "$TMPDIR/context-preserved" "$TMPDIR/context-link-target"
    if grep -qF 'wrote ' "$TMPDIR/context-refused.err"; then exit 1; fi
    if grep -qF "wrote $context_file" "$TMPDIR/context-refused-apply.err"; then exit 1; fi
    grep -qE 'failed.*agent context' "$TMPDIR/context-refused-apply.err"
    grep -qF 'Apply incomplete' "$TMPDIR/context-refused-apply.err"
    rm "$context_file"
    mv "$TMPDIR/context-link-target" "$context_file"

    # A failed temporary-file creation cannot be mistaken for a write either.
    chmod 555 "$XDG_CONFIG_HOME/agents"
    set +e
    atyrode context render >"$TMPDIR/context-unwritable.out" 2>"$TMPDIR/context-unwritable.err"
    unwritable_status="$?"
    set -e
    chmod 755 "$XDG_CONFIG_HOME/agents"
    test "$unwritable_status" != 0
    diff "$TMPDIR/context-preserved" "$context_file"
    if grep -qF 'wrote ' "$TMPDIR/context-unwritable.err"; then exit 1; fi

    # Exercise failures after temporary creation using the existing sourced
    # library seam, in a conditional (where Bash disables implicit errexit).
    # Neither partial rendering nor a failed chmod/rename may commit bytes;
    # cleanup must retain a different invocation's temporary and parent trap.
    for failure in policy chmod rename; do
      (
        source ${../../pkgs/atyrode/lib/context.sh}
        embedded_revision=unknown
        agents_policy=${../../modules/home/agents/AGENTS.md}
        say() { printf '%s\n' "$*" >&2; }
        case "$failure" in
          policy) agents_policy="$TMPDIR/absent-personal-policy" ;;
          chmod) chmod() { return 73; } ;;
          rename) mv() { return 74; } ;;
        esac
        trap 'touch "$TMPDIR/context-parent-exit"' EXIT
        printf 'other render\n' > "$XDG_CONFIG_HOME/agents/.AGENTS.md.other"
        if cmd_context render >"$TMPDIR/context-write-failed.out" 2>"$TMPDIR/context-write-failed.err"; then
          echo "context accepted a failed $failure step" >&2
          exit 1
        fi
        diff "$TMPDIR/context-preserved" "$context_file"
        if grep -qF 'wrote ' "$TMPDIR/context-write-failed.err"; then exit 1; fi
        test "$(cat "$XDG_CONFIG_HOME/agents/.AGENTS.md.other")" = 'other render'
        rm "$XDG_CONFIG_HOME/agents/.AGENTS.md.other"
        test -z "$(find "$XDG_CONFIG_HOME/agents" -name '.AGENTS.md.*' -print -quit)"
      )
      test -f "$TMPDIR/context-parent-exit"
      rm "$TMPDIR/context-parent-exit"
    done

    # Diagnostics are live, not a view of the deployed startup snapshot. Compare
    # both public formats with the healthy baseline, ignoring only display time.
    context_show_live() {
      PATH="$TMPDIR/sessionbin:$PATH" atyrode context show > "$TMPDIR/context-live"
      sed '/^Generated at /d' "$TMPDIR/context-live" |
        diff "$TMPDIR/context-default" -
      PATH="$TMPDIR/sessionbin:$PATH" atyrode context show --json > "$TMPDIR/context-live.json"
      diff <(jq -S 'del(.generatedAt)' "$TMPDIR/context-show.json") \
        <(jq -S 'del(.generatedAt)' "$TMPDIR/context-live.json")
    }

    # Health compares actual policy and known revision, not inventory age.
    # Missing, changed or manually replaced policy still requires the writer.
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
    context_probe ok ""
    printf '\nRetired diagnostic inventory\n' >> "$context_file"
    context_probe degraded context-stale
    context_show_live
    cp "$TMPDIR/context-fresh" "$context_file"
    # Development builds lack a published revision but still compare policy.
    sed -i 's/ revision [^ ]* by / revision 0123456789abcdef0123456789abcdef01234567 by /' "$context_file"
    if [[ "$stamped_revision" =~ ^[0-9a-f]{40}$ ]]; then
      context_probe degraded context-stale
    else
      context_probe ok ""
    fi
    cp "$TMPDIR/context-fresh" "$context_file"
    sed -i '1d' "$context_file"
    context_probe degraded context-stale
    # Exercise revision comparison with a published CLI, not just the unknown
    # revision used by the rest of this fixture.
    ${launcherAtyrode}/bin/atyrode context render >/dev/null
    sed -i "s/^Generated at [^ ]* /Generated at $(date -u -d '8 days ago' +%FT%TZ) /" "$context_file"
    ${launcherAtyrode}/bin/atyrode doctor provisioning --json |
      jq -e '.surfaces[] | select(.id == "agent-context") | .status == "ok"' >/dev/null
    sed -i 's/ revision [^ ]* by / revision feedfacefeedfacefeedfacefeedfacefeedface by /' "$context_file"
    ${launcherAtyrode}/bin/atyrode doctor provisioning --json |
      jq -e '.surfaces[] | select(.id == "agent-context")
        | .status == "degraded" and .code == "context-stale"' >/dev/null
    printf '# hand-written\n' > "$context_file"
    context_probe degraded context-unreadable
    context_show_live
    rm -f "$context_file"
    context_probe incomplete not-configured
    # Neither diagnostic format requires an earlier render or creates its file.
    context_show_live
    test ! -e "$context_file"
    # Off a terminal the review names the surface and the render step settles
    # it in the same run, so the machine never stays without one.
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/context-heal.err" ||
      { cat "$TMPDIR/context-heal.err" >&2; exit 1; }
    test -f "$context_file"
    context_probe ok ""

    # The durable half. A terminal scrolls; this is what a diagnosis reads
    # three weeks later, so it records the same story with timestamps and is
    # readable only by its owner.
    run_log="$(find "$XDG_STATE_HOME/atyrode/logs" -name '*-apply.log' | sort | tail -1)"
    test -n "$run_log"
    test -n "$(find "$run_log" -perm 600 -print -quit)"
    grep -qE 'run: env LC_ALL=C\.UTF-8 .*nh home switch' "$run_log"

    # provision names its targets, so a mistyped one cannot be mistaken for a
    # missing feature.
    atyrode provision nonsense 2>"$TMPDIR/provision-usage.err" && false
    grep -qF machine-key "$TMPDIR/provision-usage.err"

    # The archive is never offered: its storage document is a clan var, so
    # there is no ceremony this machine could run, only a generation an
    # operator device owes it or a fix for an archive that is placed but not
    # working. Every reading is a state of the document and the success stamp,
    # judged for a fleet machine because a portable profile has no var at all.
    babel_probe() { # host status code
      ATYRODE_HOST="$1" atyrode doctor provisioning --json |
        jq -e --arg status "$2" --arg code "$3" '
          .surfaces[] | select(.id == "babel-archive")
          | .status == $status and (.code // "") == $code
        ' >/dev/null ||
        { echo "atyrode: babel-archive on $1 was not $2/$3" >&2; exit 1; }
    }
    babel_probe development-x86_64-linux not-applicable portable-profile
    babel_probe fixture-nixos degraded archive-input-unavailable
    # Document placed but no success stamp: the archive has never run here.
    # That is configured-but-not-working, so it is told, never offered --
    # there is no yes/no in "your archive is broken", only a fix.
    mkdir -p "$XDG_CONFIG_HOME/babel"
    printf '{"password_file":"%s"}\n' "$XDG_CONFIG_HOME/babel/repository-password" > "$XDG_CONFIG_HOME/babel/storage.json"
    printf 'fixture-password\n' > "$XDG_CONFIG_HOME/babel/repository-password"
    printf '{}\n' > "$XDG_CONFIG_HOME/babel/payload-keys.json"
    babel_probe fixture-nixos degraded never-succeeded
    # A stamp older than the staleness window is degraded; a fresh one is fine.
    mkdir -p "$XDG_STATE_HOME/babel"
    date -u -d '3 days ago' +%FT%TZ > "$XDG_STATE_HOME/babel/last-success"
    babel_probe fixture-nixos degraded archive-stale
    date -u +%FT%TZ > "$XDG_STATE_HOME/babel/last-success"
    babel_probe fixture-nixos ok ""
    # A recent success must not hide an incomplete activation or lost input.
    rm "$XDG_CONFIG_HOME/babel/payload-keys.json"
    babel_probe fixture-nixos degraded archive-input-unavailable
    ln -s "$TMPDIR/missing-payload-keys" "$XDG_CONFIG_HOME/babel/payload-keys.json"
    babel_probe fixture-nixos degraded archive-input-unavailable
    rm "$XDG_CONFIG_HOME/babel/payload-keys.json"
    printf '{}\n' > "$XDG_CONFIG_HOME/babel/payload-keys.json"
    chmod 000 "$XDG_CONFIG_HOME/babel/repository-password"
    babel_probe fixture-nixos degraded archive-input-unavailable
    chmod 600 "$XDG_CONFIG_HOME/babel/repository-password"
    : > "$XDG_CONFIG_HOME/babel/repository-password"
    babel_probe fixture-nixos degraded archive-input-unavailable
    printf 'fixture-password\n' > "$XDG_CONFIG_HOME/babel/repository-password"
    cp "$XDG_CONFIG_HOME/babel/storage.json" "$TMPDIR/valid-babel-storage"
    printf '{}\n' > "$XDG_CONFIG_HOME/babel/storage.json"
    babel_probe fixture-nixos degraded archive-config-invalid
    mv "$TMPDIR/valid-babel-storage" "$XDG_CONFIG_HOME/babel/storage.json"
    babel_probe fixture-nixos ok ""
    # Arming is an apply-owned mutation. A refused start must make the apply
    # fail, and the announced start is what shows the arm branch ran rather
    # than the skip for a missing document.
    set +e
    _ATYRODE_TEST_SYSTEMD_AVAILABLE=0 ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/apply-archive-arm.err"
    archive_status="$?"
    set -e
    test "$archive_status" = 69
    grep -qE '^  \$ .*fake-systemctl --user start babel-archive\.timer$' "$TMPDIR/apply-archive-arm.err"
    grep -qF 'now?' "$TMPDIR/apply-archive-arm.err" && false
    rm -rf "$XDG_CONFIG_HOME/babel" "$XDG_STATE_HOME/babel"

    # The broker token is the same shape as the archive document: a shared
    # clan var an operator device generates and the next apply places behind
    # ~/.omp/auth-broker.token. The surface reads the link and the inventory
    # (fleet/auth-broker.json names the serving host; every other clan machine
    # tunnels) and never a vault; a portable profile has no var to read.
    broker_probe() { # host status code
      ATYRODE_HOST="$1" atyrode doctor provisioning --json |
        jq -e --arg status "$2" --arg code "$3" '
          .surfaces[] | select(.id == "omp-auth-broker")
          | .status == $status and (.code // "") == $code
        ' >/dev/null ||
        { echo "atyrode: omp-auth-broker on $1 was not $2/$3" >&2; exit 1; }
    }
    broker_probe development-x86_64-linux not-applicable portable-profile
    broker_probe fixture-nixos degraded not-generated
    ATYRODE_HOST=fixture-nixos atyrode doctor provisioning --json | jq -e --arg token "$HOME/.omp/auth-broker.token" '
      .surfaces[] | select(.id == "omp-auth-broker")
      | (.summary | startswith("tunnel mode, broker host dev-01: no bearer token at " + $token))
        and .remediation == "clan vars generate fixture-nixos (on an operator device), then atyrode apply"' >/dev/null
    mkdir -p "$HOME/.omp"
    printf 'BROKER-TOKEN-TEST' > "$HOME/.omp/auth-broker.token"
    broker_probe fixture-nixos ok ""
    ATYRODE_HOST=fixture-nixos atyrode doctor provisioning --json > "$TMPDIR/broker-placed.json"
    jq -e '.surfaces[] | select(.id == "omp-auth-broker")
      | .summary == "tunnel mode, broker host dev-01: bearer token placed"' "$TMPDIR/broker-placed.json" >/dev/null
    grep -qF 'BROKER-TOKEN-TEST' "$TMPDIR/broker-placed.json" && false
    rm "$HOME/.omp/auth-broker.token"

    # The Git identity is a clan var: on a portable profile it is not
    # applicable, and apply neither offers nor asks anything about it.
    atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/git-identity-quiet.err" ||
      { cat "$TMPDIR/git-identity-quiet.err" >&2; exit 1; }
    atyrode doctor provisioning --json |
      jq -e '.surfaces[] | select(.id == "git-identity")
        | .status == "not-applicable" and .code == "portable-profile"' >/dev/null
    # Supervised submission must finish without echoing its inherited
    # environment to the operator.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    live_out="$(_ATYRODE_TEST_TTY=1 \
      _ATYRODE_TEST_SYSTEMD_AVAILABLE=1 \
      ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      atyrode apply --repo "$HOME/nix-dotfiles" 2>&1 </dev/null)" ||
      { printf '%s\n' "$live_out" >&2; exit 1; }
    if grep -qF -- '--setenv=PATH=' <<<"$live_out"; then
      echo 'the systemd handoff printed its forwarded environment to the terminal' >&2
      exit 1
    fi
    live_job="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    jq -e '.phase == "succeeded" and .exitCode == 0 and .activationCompleted == true' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$live_job/result.json" >/dev/null
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"

    # A degraded surface whose remedy is itself a dialogue. The seeder asks the
    # questions rather than answering them, so apply runs it instead of quoting
    # it -- which is exactly what makes announcing it non-negotiable: the next
    # thing on this terminal is a prompt from another program, and an operator
    # must never be questioned by something they did not see start.
    {
      printf '#!${pkgs.runtimeShell}\n'
      printf 'case "$1" in\n'
      printf '  status) printf %s ;;\n' \
        "'"'{"pending":[],"drift":[{"key":"recap.enabled","reason":"local-edit"},{"key":"extendedContext","reason":"local-edit"}]}\n'"'"
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
    printf '%s\n' "$seed_out" | grep -qE '^  \$ atyrode-omp-seed resolve$'
    # The dialogue's own output follows the line that named it, in that order.
    printf '%s\n' "$seed_out" | grep -qF 'seeder: reviewing 2 kept settings'
    test "$(printf '%s\n' "$seed_out" | grep -n 'atyrode-omp-seed resolve' | head -1 | cut -d: -f1)" \
      -lt "$(printf '%s\n' "$seed_out" | grep -n 'seeder: reviewing' | head -1 | cut -d: -f1)"
    rm -f "$TMPDIR/bin/atyrode-omp-seed" "$XDG_STATE_HOME/atyrode/provisioning-declined"

    printf '%s\n' sentinel > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    export ATYRODE_NH_FAIL=1
    rm -f "$TMPDIR/nh-activations"
    if atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/nh-fail.err"; then
      echo 'failed activation unexpectedly succeeded' >&2
      exit 1
    fi
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
    test ! -e "$TMPDIR/nh-activations"
    unset ATYRODE_NH_FAIL

    atyrode apply --repo "$HOME/nix-dotfiles" --dry-run >/dev/null
    grep -F -- "home switch path:$(cat "$TMPDIR/runtime-adapter-path") --configuration development-x86_64-linux" \
      "$TMPDIR/nh-args" >/dev/null
    grep -qF "inputs.dotfiles.url = \"path:$HOME/nix-dotfiles\"" "$TMPDIR/runtime-adapter/flake.nix"
    grep -F -- '--dry' "$TMPDIR/nh-args" >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

    preview="$(atyrode apply --repo "$HOME/nix-dotfiles" --preview-json 2>"$TMPDIR/preview.err")"
    jq -e '
      .schemaVersion == 1
      and .host == "development-x86_64-linux"
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
    grep -qE '^\$ env LC_ALL=C.UTF-8 .*nh home switch .* --dry$' "$TMPDIR/preview.err"

    # Package-version output cannot authorize a service restart. These real
    # command-boundary cases inspect different immutable generation trees.
    (
      export ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl"
      export ATYRODE_TEST_CANDIDATE=${ownerNew}
      ln -sfn ${ownerOld} "$XDG_STATE_HOME/home-manager/gcroots/current-home"
      rm -f "$TMPDIR/nh-activations"
      owner_preview="$(atyrode apply --repo "$HOME/nix-dotfiles" --preview-json)"
      jq -e '.disruption.status == "blocked" and
        any(.disruption.effects[]; .service == "manifold-agent.service" and
          .protected and (.action == "restart" or .action == "stop"))' \
        <<<"$owner_preview" >/dev/null
      set +e
      atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>"$TMPDIR/owner-refused.err"
      refused_status="$?"
      set -e
      test "$refused_status" = 69
      test ! -e "$TMPDIR/nh-activations"
      test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

      # An absence-based preview is stale if the owner returns before the locked apply.
      inactive_preview="$(ATYRODE_TEST_OWNER_ACTIVE=inactive atyrode apply --repo "$HOME/nix-dotfiles" --preview-json)"
      inactive_fingerprint="$(jq -er '.disruption | select(.status == "safe") | .fingerprint' <<<"$inactive_preview")"
      set +e
      atyrode apply --repo "$HOME/nix-dotfiles" --expected-disruption "$inactive_fingerprint" >/dev/null 2>&1
      returned_owner_status="$?"
      set -e
      test "$returned_owner_status" = 69
      test ! -e "$TMPDIR/nh-activations"
      ATYRODE_TEST_OWNER_ACTIVE=inactive atyrode apply --repo "$HOME/nix-dotfiles" \
        --expected-disruption "$inactive_fingerprint" >/dev/null 2>&1
      test -s "$TMPDIR/nh-activations"
      rm "$TMPDIR/nh-activations"

      export ATYRODE_TEST_CANDIDATE=${scopedNew}
      ln -sfn ${scopedOld} "$XDG_STATE_HOME/home-manager/gcroots/current-home"
      scoped_preview="$(atyrode apply --repo "$HOME/nix-dotfiles" --preview-json --scope user:caddy.service)"
      fingerprint="$(jq -er '.disruption | select(.status == "safe") | .fingerprint' <<<"$scoped_preview")"
      set +e
      atyrode apply --repo "$HOME/nix-dotfiles" --scope user:other.service >/dev/null 2>&1
      scope_status="$?"
      set -e
      test "$scope_status" = 69
      test ! -e "$TMPDIR/nh-activations"

      # A different running generation invalidates the fingerprint even when
      # the candidate and its package-version diff stayed the same.
      ln -sfn "$ATYRODE_TEST_CURRENT" "$XDG_STATE_HOME/home-manager/gcroots/current-home"
      set +e
      atyrode apply --repo "$HOME/nix-dotfiles" --expected-disruption "$fingerprint" >/dev/null 2>&1
      stale_status="$?"
      set -e
      test "$stale_status" = 65
      test ! -e "$TMPDIR/nh-activations"

      export ATYRODE_TEST_CANDIDATE=${unknownCandidate}
      set +e
      atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>&1
      unknown_status="$?"
      set -e
      test "$unknown_status" = 69
      test ! -e "$TMPDIR/nh-activations"

      export ATYRODE_TEST_CANDIDATE=${scopedNew}
      export ATYRODE_GEN_PROFILE="$TMPDIR/guard-existing-profile"
      touch "$ATYRODE_GEN_PROFILE"
      rm "$XDG_STATE_HOME/home-manager/gcroots/current-home"
      set +e
      atyrode apply --repo "$HOME/nix-dotfiles" >/dev/null 2>&1
      unknown_current_status="$?"
      set -e
      test "$unknown_current_status" = 69
      test ! -e "$TMPDIR/nh-activations"
      ln -s "$ATYRODE_TEST_CURRENT" "$XDG_STATE_HOME/home-manager/gcroots/current-home"
    )

    # The target revision must govern the whole apply, including host
    # resolution and post-switch diagnostics, even when the launcher is old.
    cat > "$TMPDIR/bin/handoff-nix" <<'EOF'
    #!${pkgs.runtimeShell}
    [[ "$*" == 'build --no-link --print-out-paths github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface#atyrode' ]] || exit 64
    printf '%s\n' ${targetAtyrode}
    EOF
    chmod +x "$TMPDIR/bin/handoff-nix"
    ATYRODE_NIX="$TMPDIR/bin/handoff-nix" ${launcherAtyrode}/bin/atyrode apply --json \
      > "$TMPDIR/handoff.out" 2> "$TMPDIR/handoff.err"
    grep -q 'revision feedfacefeedfacefeedfacefeedfacefeedface by' "$context_file"
    sed '/^Generated at /d' "$context_file" | diff "$TMPDIR/candidate-context-policy" -
    if grep -qE 'remaining.*agent-context|context-stale' "$TMPDIR/handoff.err"; then
      echo 'published handoff left a false context blocker' >&2
      exit 1
    fi
    rm "$TMPDIR/bin/handoff-nix"
    printf '%s\n' sentinel > "$XDG_STATE_HOME/atyrode/dotfiles-config"
    atyrode apply --plan --json | jq -e '
      .source == "remote"
      and .revision == "feedfacefeed"
      and .resolvedRevision == "feedfacefeedfacefeedfacefeedfacefeedface"
      and .installable == "github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface#development-x86_64-linux"
      and (.dirty | not)
      and .repository == "github:atyrode/dotfiles"
    ' >/dev/null
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel

    atyrode apply >/dev/null
    # A portable profile activates through its runtime adapter flake, whose
    # dotfiles input pins the resolved revision; nh home receives the adapter
    # bare, since a #fragment form is passed to nix verbatim and fails
    # attribute resolution.
    grep -Fx -- "home switch $ATYRODE_TEST_CANDIDATE --backup-extension backup --diff always" \
      "$TMPDIR/nh-args" >/dev/null
    grep -qF 'inputs.dotfiles.url = "github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface"' \
      "$TMPDIR/runtime-adapter/flake.nix"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = development-x86_64-linux

    # The user manager, not the invoking terminal, owns a mutating apply. Kill
    # the waiting CLI while nh is blocked and prove the private worker still
    # publishes its result. Active apply units also reject overlap.
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
    set +e
    atyrode apply --repo "$HOME/nix-dotfiles" >"$TMPDIR/overlap.out" 2>"$TMPDIR/overlap.err"
    overlap_status="$?"
    set -e
    test "$overlap_status" = 69
    kill "$apply_caller"
    wait "$apply_caller" 2>/dev/null || true
    job_id="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    # Build and switch are separate backend calls, followed by the normal convergence probes.
    for _ in $(seq 1 600); do
      [[ ! -e "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/result.json" ]] || break
      sleep 0.05
    done
    if [[ ! -e "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/result.json" ]]; then
      cat "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/output.log" >&2
      echo 'detached worker did not publish its result within 30 seconds' >&2
      exit 1
    fi
    jq -e '.phase == "succeeded" and .exitCode == 0' \
      "$XDG_STATE_HOME/atyrode/apply-jobs/$job_id/result.json" >/dev/null
    apply_status="$(atyrode apply-status "$job_id" --json)"
    jq -e '
      .jobId == $job
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
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = development-x86_64-linux

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
    killed_job="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    worker_pid="$(cat "$TMPDIR/fake-systemd/atyrode-apply-$killed_job.service.pid")"
    kill -9 -"$worker_pid" 2>/dev/null || kill -9 "$worker_pid" 2>/dev/null || true
    set +e
    wait "$apply_caller"
    killed_status="$?"
    set -e
    test "$killed_status" = 70
    killed_job="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    if [[ -e "$XDG_STATE_HOME/atyrode/apply-jobs/$killed_job/result.json" ]]; then
      echo 'killed worker unexpectedly published a result' >&2
      exit 1
    fi
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

    if atyrode apply development-aarch64-linux --plan >/dev/null 2>&1; then
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
    export _ATYRODE_TEST_HOSTNAME=wsl
    : > "$WINGET_LOG"

    windows_plan="$(atyrode windows plan wsl --json)"
    jq -e '
      .schemaVersion == 2
      and .host == "wsl"
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
    wsl_apply_plan="$(atyrode apply wsl --repo "$HOME/nix-dotfiles" --plan --json)"
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

    # The machine key is placed before the switch, so the activation that
    # follows can decrypt this machine's vars. clan is stubbed to hand out a
    # sentinel and sudo to run the announced argv as the sandbox user; the
    # root-owned path is relocated under a scratch root. What the operator
    # reads is the pipeline itself -- the key travels through it and never
    # through argv or any stream.
    cat > "$TMPDIR/bin/clan" <<'EOF'
    #!${pkgs.runtimeShell}
    printf '%s\n' "$*" >> "$TMPDIR/clan-args"
    if [[ -n "''${SOPS_CIPHERTEXT:-}" ]]; then
      XDG_CONFIG_HOME="$TMPDIR/platform-default" ${pkgs.sops}/bin/sops decrypt \
        --input-type binary --output-type binary "$SOPS_CIPHERTEXT" >/dev/null || exit $?
    fi
    [[ "''${1:-}" == secrets && "''${2:-}" == get ]] || exit 64
    printf 'AGE-SECRET-KEY-1FIXTUREONLY\n'
    EOF
    chmod +x "$TMPDIR/bin/clan"
    export ATYRODE_CLAN="$TMPDIR/bin/clan"
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
    machine_root="$TMPDIR/wsl-machine"
    export _ATYRODE_TEST_IDENTITY_ROOT="$machine_root"
    machine_key="$machine_root/var/lib/sops-nix/key.txt"
    mkdir -p "$HOME/nix-dotfiles/sops/secrets/wsl-age.key"
    printf '{"data":"ENC[AES256_GCM,fixture]","sops":{"age":[]}}\n' > "$HOME/nix-dotfiles/sops/secrets/wsl-age.key/secret"
    # Without a registered operator key on this device, applying must stop
    # before the switch that would ask sops-nix for the absent machine key.
    mv "$operator_key" "$operator_key.aside"
    rm -f "$TMPDIR/clan-args" "$TMPDIR/nh-args" "$TMPDIR/nh-activations"
    set +e
    atyrode apply wsl --repo "$HOME/nix-dotfiles" --json >/dev/null 2>"$TMPDIR/wsl-apply-nodevice.err"
    nodevice_status="$?"
    set -e
    test "$nodevice_status" != 0
    test ! -e "$TMPDIR/clan-args"
    test ! -e "$TMPDIR/nh-activations"
    test ! -e "$machine_key"
    mv "$operator_key.aside" "$operator_key"
    # Exercise the actual SOPS reader with a different platform default,
    # without a login exporting the identity file. Registration is covered
    # above; this disposable software identity exercises file discovery, not
    # the Darwin-only Secure Enclave hardware.
    cp "$operator_key" "$TMPDIR/operator-key.saved"
    rm "$operator_key"
    ${pkgs.age}/bin/age-keygen -o "$operator_key" 2>/dev/null
    sops_recipient="$(${pkgs.age}/bin/age-keygen -y "$operator_key")"
    sed -i "s/^# public key: .*/# public key: $device_recipient/" "$operator_key"
    export SOPS_CIPHERTEXT="$TMPDIR/discovery.enc"
    printf 'disposable machine-key test\n' |
      sops encrypt --age "$sops_recipient" --input-type binary --output-type binary /dev/stdin > "$SOPS_CIPHERTEXT"
    unset SOPS_AGE_KEY_FILE
    rm -f "$TMPDIR/nh-args"
    if ! wsl_apply="$(atyrode apply wsl --repo "$HOME/nix-dotfiles" --json \
      2>"$TMPDIR/wsl-apply.err")"; then
      echo 'apply failed while placing the machine key; its diagnosis follows' >&2
      cat "$TMPDIR/wsl-apply.err" >&2
      exit 1
    fi
    jq -e '.activation == "nixos-wsl" and .backend == "nh-os"' <<<"$wsl_apply" >/dev/null
    ${pkgs.python3.interpreter} ${./apply-plan.py} \
      "$TMPDIR/wsl-apply.err" "$TMPDIR/wsl-apply-nodevice.err" "$TMPDIR/nh-fail.err"
    grep -qE "^  \\$ sudo -- \\S*install -D -m 0600 -o root \\S+/key\\.txt $machine_key\$" \
      "$TMPDIR/wsl-apply.err"
    # The decrypted key is staged in a mode-700 directory and the directory
    # goes with the step, whatever the step's outcome.
    staged_dir="$(sed -n "s|^  \\$ $TMPDIR/bin/clan secrets get .* > \\(.*\\)/key\\.txt\$|\\1|p" \
      "$TMPDIR/wsl-apply.err" | head -n 1)"
    test -n "$staged_dir"
    test ! -e "$staged_dir"
    grep -qF "secrets get wsl-age.key --flake $HOME/nix-dotfiles" "$TMPDIR/clan-args"
    test "$(cat "$machine_key")" = AGE-SECRET-KEY-1FIXTUREONLY
    test "$(stat -c %a "$machine_key")" = 600
    grep -qF 'AGE-SECRET-KEY' "$TMPDIR/wsl-apply.err" && false
    grep -qF 'AGE-SECRET-KEY' <<<"$wsl_apply" && false
    mv "$TMPDIR/operator-key.saved" "$operator_key"
    rm "$SOPS_CIPHERTEXT"
    unset SOPS_CIPHERTEXT
    # Placed once: the next apply skips it without asking clan again.
    rm -f "$TMPDIR/clan-args"
    atyrode apply wsl --repo "$HOME/nix-dotfiles" --json >/dev/null 2>"$TMPDIR/wsl-apply-placed.err"
    test ! -e "$TMPDIR/clan-args"
    # A spoke applies a published revision, not a checkout: the key is read
    # from the flake's fetched tree -- the bytes nh builds -- and never from
    # whatever ~/nix-dotfiles happens to hold. Here the checkout is stale
    # (no key) while the fetched tree has one; WSL's first apply after #542
    # found it the other way round and skipped placement.
    rm -rf "$machine_root" "$HOME/nix-dotfiles/sops/secrets/wsl-age.key"
    fetched_tree="$TMPDIR/fetched-tree"
    mkdir -p "$fetched_tree/sops/secrets/wsl-age.key"
    printf '{"data":"ENC[AES256_GCM,fixture]","sops":{"age":[]}}\n' > "$fetched_tree/sops/secrets/wsl-age.key/secret"
    remote_rev=0123456789012345678901234567890123456789
    cat > "$TMPDIR/bin/nix" <<EOF
    #!${pkgs.runtimeShell}
    printf '%s\n' "\$*" >> "$TMPDIR/nix-args"
    [[ "\$*" == "flake prefetch --json github:atyrode/dotfiles/$remote_rev" ]] || exit 64
    printf '{"storePath":"%s"}\n' "$fetched_tree"
    EOF
    chmod +x "$TMPDIR/bin/nix"
    export ATYRODE_NIX="$TMPDIR/bin/nix"
    # The stub keeps only the last nh argv; the checkout run's is read below.
    mv "$TMPDIR/nh-args" "$TMPDIR/nh-args.checkout"
    rm -f "$TMPDIR/clan-args" "$TMPDIR/nix-args"
    if ! atyrode apply wsl --ref "$remote_rev" --json >/dev/null 2>"$TMPDIR/wsl-apply-remote.err"; then
      echo 'a remote apply failed while placing the machine key; its diagnosis follows' >&2
      cat "$TMPDIR/wsl-apply-remote.err" >&2
      exit 1
    fi
    grep -qF "flake prefetch --json github:atyrode/dotfiles/$remote_rev" "$TMPDIR/nix-args"
    grep -qF "secrets get wsl-age.key --flake $fetched_tree" "$TMPDIR/clan-args"
    test "$(cat "$machine_key")" = AGE-SECRET-KEY-1FIXTUREONLY
    grep -Fx -- "os switch $ATYRODE_TEST_CANDIDATE --diff always" \
      "$TMPDIR/nh-args" >/dev/null
    mv "$TMPDIR/nh-args.checkout" "$TMPDIR/nh-args"
    rm -rf "$fetched_tree" "$TMPDIR/bin/nix" "$TMPDIR/nix-args"
    unset ATYRODE_NIX

    # An update is a prompt, never a background switch. `changelog` reads what
    # main has that this machine does not, `--record` leaves that for the shell,
    # and every new shell repeats one line until the machine runs main -- a shell
    # an agent opened and closed must not be the one that dismissed it. Nothing
    # here may touch nh.
    receipt="$XDG_STATE_HOME/atyrode/update.json"
    cat > "$TMPDIR/bin/changelog-fetch" <<EOF
    #!${pkgs.runtimeShell}
    printf '%s\n' "\$*" >> "$TMPDIR/changelog-fetch-args"
    case "\$*" in
      *'/compare/1111111111111111111111111111111111111111...feedfacefeedfacefeedfacefeedfacefeedface')
        printf '%s\n' '{"status":"ahead","ahead_by":2,"commits":[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commit":{"message":"feat(atyrode): the shell reads main\n\nbody"}},{"sha":"feedfacefeedfacefeedfacefeedfacefeedface","commit":{"message":"fix: retain manifold ingress"}}]}' ;;
      *'/commits/feedfacefeedfacefeedfacefeedfacefeedface/check-runs')
        cat "$TMPDIR/changelog-check-runs" ;;
      *) exit 22 ;;
    esac
    EOF
    chmod +x "$TMPDIR/bin/changelog-fetch"
    export ATYRODE_FETCH="$TMPDIR/bin/changelog-fetch"
    rm -f "$TMPDIR/nh-activations" "$TMPDIR/nh-args"
    # Current: main is what this CLI was built from; nothing is asked of GitHub.
    ${targetAtyrode}/bin/atyrode changelog > "$TMPDIR/changelog-current.out" 2> "$TMPDIR/changelog-current.err" \
      || { echo "changelog failed: $(cat "$TMPDIR/changelog-current.err")" >&2; exit 1; }
    test ! -e "$TMPDIR/changelog-fetch-args"
    ${targetAtyrode}/bin/atyrode changelog --json | jq -e '.outcome == "current" and .ahead == 0 and .commits == []' >/dev/null
    # Behind, with a green main: both commits listed oldest first as subjects
    # only, the verdict names the cache, and the remedy is apply.
    printf '%s\n' '{"check_runs":[{"name":"ci-gate","status":"completed","conclusion":"success"},{"name":"classify","status":"completed","conclusion":"success"}]}' \
      > "$TMPDIR/changelog-check-runs"
    ${launcherAtyrode}/bin/atyrode changelog > "$TMPDIR/changelog-behind.out" 2> "$TMPDIR/changelog-behind.err" \
      || { echo "changelog behind failed: $(cat "$TMPDIR/changelog-behind.err")" >&2; exit 1; }
    grep -qF 'body' "$TMPDIR/changelog-behind.out" && false
    ${launcherAtyrode}/bin/atyrode changelog --json | jq -e '
      .outcome == "available" and .ahead == 2 and .green == true
      and .running == "1111111111111111111111111111111111111111"
      and .target == "feedfacefeedfacefeedfacefeedfacefeedface"
      and (.commits | map(.sha)) == ["aaaaaaaaaaaa", "feedfacefeed"]
      and (.commits | map(.subject)) == ["feat(atyrode): the shell reads main", "fix: retain manifold ingress"]
    ' >/dev/null
    # A red or unfinished main is said as such, never mistaken for green.
    printf '%s\n' '{"check_runs":[{"name":"ci-gate","status":"completed","conclusion":"failure"}]}' > "$TMPDIR/changelog-check-runs"
    ${launcherAtyrode}/bin/atyrode changelog --json | jq -e '.outcome == "available" and .green == false and .ahead == 2' >/dev/null
    printf '%s\n' '{"check_runs":[{"name":"ci-gate","status":"in_progress","conclusion":null}]}' > "$TMPDIR/changelog-check-runs"
    ${launcherAtyrode}/bin/atyrode changelog --json | jq -e '.green == null' >/dev/null
    # The record is what the shell reads: nothing without one, one line with
    # one, the same line again on the next shell, and silence from a CLI that
    # already runs the recorded target even before the next hourly look.
    test -z "$(${launcherAtyrode}/bin/atyrode __update-notice)"
    printf '%s\n' '{"check_runs":[{"name":"ci-gate","status":"completed","conclusion":"success"}]}' > "$TMPDIR/changelog-check-runs"
    ${launcherAtyrode}/bin/atyrode changelog --record >/dev/null
    jq -e '.outcome == "available" and .target == "feedfacefeedfacefeedfacefeedfacefeedface" and .green == true' "$receipt" >/dev/null
    ${launcherAtyrode}/bin/atyrode __update-notice > "$TMPDIR/update-notice.out"
    test -s "$TMPDIR/update-notice.out"
    test "$(${launcherAtyrode}/bin/atyrode __update-notice)" = "$(cat "$TMPDIR/update-notice.out")"
    test -z "$(${targetAtyrode}/bin/atyrode __update-notice)"
    # doctor says the same from a live comparison, with the same two commands.
    ${launcherAtyrode}/bin/atyrode doctor provisioning --json | jq -e '
      .surfaces[] | select(.id == "convergence")
      | .status == "degraded" and .code == "behind"
        and (.summary | contains("main is feedfacefeed") and contains("runs 111111111111"))
        and .remediation == "atyrode changelog to read what changed, then atyrode apply"
    ' >/dev/null
    ${targetAtyrode}/bin/atyrode doctor provisioning --json | jq -e '
      .surfaces[] | select(.id == "convergence") | .status == "ok"
    ' >/dev/null
    # A development build has no revision to compare and says so.
    set +e
    atyrode changelog >/dev/null 2>"$TMPDIR/changelog-dev.err"
    changelog_dev_status="$?"
    set -e
    test "$changelog_dev_status" = 69
    grep -qF 'development build' "$TMPDIR/changelog-dev.err"
    test ! -e "$TMPDIR/nh-activations"
    test ! -e "$TMPDIR/nh-args"
    rm -f "$receipt" "$TMPDIR/bin/changelog-fetch" "$TMPDIR/changelog-check-runs" "$TMPDIR/changelog-fetch-args"
    unset ATYRODE_FETCH
    # After the switch, the review names the host apply switched. The id
    # recorded under ~/.config is a Home Manager file that NixOS relinks from
    # a unit the activation only restarts; a stale one (here: the name the
    # host had before #517) must not turn the review into "unknown host".
    mv "$XDG_CONFIG_HOME/atyrode/host.json" "$TMPDIR/host.json.aside"
    printf '{"id":"alex-x86_64-linux-wsl"}\n' > "$XDG_CONFIG_HOME/atyrode/host.json"
    if ! atyrode apply wsl --repo "$HOME/nix-dotfiles" --json >/dev/null 2>"$TMPDIR/wsl-apply-stale.err"; then
      echo 'apply failed with a stale host record; its diagnosis follows' >&2
      cat "$TMPDIR/wsl-apply-stale.err" >&2
      exit 1
    fi
    mv "$TMPDIR/host.json.aside" "$XDG_CONFIG_HOME/atyrode/host.json"
    rm -f "$TMPDIR/bin/sudo" "$TMPDIR/bin/clan"
    rm -rf "$machine_root" "$HOME/nix-dotfiles/sops/secrets/wsl-age.key"
    unset ATYRODE_CLAN _ATYRODE_TEST_IDENTITY_ROOT
    grep -Fx -- "os switch $ATYRODE_TEST_CANDIDATE --diff always" \
      "$TMPDIR/nh-args" >/dev/null
    grep -F -- 'install --id Zen-Team.Zen-Browser.Twilight --exact --source winget' \
      "$WINGET_LOG" >/dev/null
    grep -F -- 'install --id DEVCOM.JetBrainsMonoNerdFont --exact --source winget' \
      "$WINGET_LOG" >/dev/null
    test -f "$WINGET_STATE/twilight"
    test -f "$WINGET_STATE/jetbrains-nerd-font"
    converged_windows="$(atyrode windows plan wsl --json)"
    jq -e '.ready and .converged and .changes == 0 and all(.packages[]; .status == "installed")' \
      <<<"$converged_windows" >/dev/null \
      || { echo "Windows plan did not converge after apply: $converged_windows" >&2; exit 1; }

    rm -f "$WINGET_STATE/twilight"
    touch "$WINGET_STATE/stable"
    : > "$WINGET_LOG"
    set +e
    blocked_plan="$(atyrode windows plan wsl --json)"
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
    atyrode windows apply wsl --json \
      > "$TMPDIR/windows-blocked.out" 2> "$TMPDIR/windows-blocked.err"
    windows_blocked_status="$?"
    set -e
    test "$windows_blocked_status" = 69
    grep -qF 'install --id' "$WINGET_LOG" && false
    test ! -e "$WINGET_STATE/twilight"

    set +e
    ATYRODE_WINGET="$TMPDIR/bin/missing-winget.exe" \
      atyrode windows plan wsl --json \
      > "$TMPDIR/windows-unavailable.out" 2> "$TMPDIR/windows-unavailable.err"
    windows_unavailable_status="$?"
    set -e
    test "$windows_unavailable_status" = 69
    test ! -s "$TMPDIR/windows-unavailable.out"

    # The detached apply job must fail the same way as the synchronous path.
    # apply_config's command substitutions are unguarded because it assumes
    # errexit, and the worker's `set +e` was inherited by the subshell running
    # it: windows_plan's failure then became an empty string that reached
    # `jq --argjson` as a raw parse error, and the job still published success.
    rm -rf "$XDG_STATE_HOME/atyrode/apply-jobs" "$TMPDIR/fake-systemd"
    rm -f "$TMPDIR/nh-activations"
    set +e
    _ATYRODE_TEST_SYSTEMD_AVAILABLE=1 \
      ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      ATYRODE_WINGET="$TMPDIR/bin/missing-winget.exe" \
      atyrode apply wsl --repo "$HOME/nix-dotfiles" \
      > "$TMPDIR/wsl-job.out" 2> "$TMPDIR/wsl-job.err"
    wsl_job_status="$?"
    set -e
    test "$wsl_job_status" = 69
    test ! -e "$TMPDIR/nh-activations"
    wsl_job_id="$(cat "$XDG_STATE_HOME/atyrode/apply-jobs/latest")"
    jq -e '.phase == "failed" and .exitCode == 69 and .activationCompleted == false' \
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
    mv "$XDG_CONFIG_HOME/atyrode/host.json" "$TMPDIR/host.json.before-worker"
    printf '%s\n' '{"id":"alex-x86_64-linux-wsl"}' > "$XDG_CONFIG_HOME/atyrode/host.json"
    printf '#!${pkgs.runtimeShell}\nexit 0\n' > "$TMPDIR/bin/cmd.exe"
    chmod +x "$TMPDIR/bin/cmd.exe"
    set +e
    env -u ATYRODE_WINGET \
      WSLPATH="$TMPDIR/bin" \
      ATYRODE_HOST=alex-x86_64-linux-wsl ATYRODE_TEST_MANAGER_HOST=dev-01 \
      _ATYRODE_TEST_SYSTEMD_AVAILABLE=1 \
      ATYRODE_SYSTEMD_RUN="$TMPDIR/bin/fake-systemd-run" \
      ATYRODE_SYSTEMCTL="$TMPDIR/bin/fake-systemctl" \
      atyrode apply --repo "$HOME/nix-dotfiles" \
      > "$TMPDIR/wsl-path.out" 2> "$TMPDIR/wsl-path.err"
    wsl_path_status="$?"
    set -e
    if [[ "$wsl_path_status" != 0 ]]; then
      echo "apply through the job worker failed with $wsl_path_status" >&2
      exit 1
    fi
    grep -qF -- '--version' "$WINGET_LOG"
    mv "$TMPDIR/host.json.before-worker" "$XDG_CONFIG_HOME/atyrode/host.json"

    # A plan whose query fails installs nothing; the log is cleared so the
    # negative reads this run alone and not the apply above.
    : > "$WINGET_LOG"
    set +e
    WINGET_QUERY_ERROR=1 atyrode windows plan wsl --json \
      > "$TMPDIR/windows-query-error.out" 2> "$TMPDIR/windows-query-error.err"
    windows_query_error_status="$?"
    set -e
    test "$windows_query_error_status" = 69
    test ! -s "$TMPDIR/windows-query-error.out"
    grep -qF '(exit 45)' "$TMPDIR/windows-query-error.err"
    grep -qF 'install --id' "$WINGET_LOG" && false

    unset ATYRODE_WINGET WINGET_LOG WINGET_STATE _ATYRODE_TEST_WSL
    export _ATYRODE_TEST_HOSTNAME=fixture-linux
    printf '%s\n' development-x86_64-linux > "$XDG_STATE_HOME/atyrode/dotfiles-config"

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
    system_result="$(atyrode doctor system fixture-desktop --json)"
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
        "homebrew-drift",
        "bootstrap-residue"
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

    # A Home Manager-only Linux host whose daemon predates the fleet cache: trust and
    # signatures are right, only the cache lists lag. No Nix layer owns
    # /etc/nix/nix.conf there, so the remediation must be the exact privileged
    # line that enrols the daemon, not a pointer to a configuration nobody has.
    linux_stale_cache="$TMPDIR/linux-stale-cache.json"
    jq '.nix.substitutersExact = false | .nix.trustedKeysExact = false' "$linux_ready" > "$linux_stale_cache"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$linux_stale_cache"
    if atyrode doctor system fixture-desktop --json > "$TMPDIR/linux-stale-cache.out"; then
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

    minimal_result="$(atyrode doctor system development-x86_64-linux --json)"
    # development-x86_64-linux carries the containers capability but not mobile, so
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
    if atyrode doctor system fixture-desktop --json > "$TMPDIR/antivirus-present.out"; then
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
    if atyrode doctor system fixture-desktop --json \
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
    atyrode doctor system fixture-desktop --json | jq -e '.ok' >/dev/null

    chmod 000 "$android_rules/51-android.rules"
    if atyrode doctor system fixture-desktop --json \
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
    if atyrode doctor system fixture-desktop --json > "$TMPDIR/linux-incomplete.out"; then
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
    export _ATYRODE_TEST_HOSTNAME=wsl
    wsl_result="$(atyrode doctor system wsl --json)"
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
    # The residue probe reads a real /etc unless a scenario relocates it, and
    # the Darwin builder has one; every reading below is about the fixture,
    # not about the machine CI happens to run on.
    mkdir -p "$TMPDIR/etc-clean"
    export _ATYRODE_TEST_ETC_ROOT="$TMPDIR/etc-clean"
    if ! darwin_result="$(atyrode doctor system macbook --json \
      2>"$TMPDIR/darwin-ready.err")"; then
      echo 'the ready Darwin fixture did not pass diagnostics' >&2
      cat "$TMPDIR/darwin-ready.err" >&2
      printf '%s\n' "$darwin_result" >&2
      exit 1
    fi
    jq -e '
      .ok
      and .platform == "darwin"
      and (.checks[] | select(.id == "container-engine") | .actual.mode) == "orbstack"
      and (.checks[] | select(.id == "device-permissions") | .status) == "ok"
      and (.checks[] | select(.id == "homebrew-drift") | .status) == "ok"
    ' <<< "$darwin_result" >/dev/null
    jq -e '(.checks[] | select(.id == "bootstrap-residue")
      | .status == "ok" and .owner == "bootstrap")' <<<"$darwin_result" >/dev/null

    # Each state install.sh repairs before Nix exists, seen once Nix does.
    dirty_etc="$TMPDIR/etc-dirty"
    mkdir -p "$dirty_etc/profile.d" "$dirty_etc/ssl/certs" "$dirty_etc/nix" "$dirty_etc/zsh"
    printf 'original bashrc\n' > "$dirty_etc/bashrc.backup-before-nix"
    printf 'installer bashrc\n' > "$dirty_etc/bashrc"
    { printf 'export PATH=/nix/var/nix/profiles/default/bin\n'; printf '# End Nix\n'; } \
      > "$dirty_etc/zshrc"
    ln -s /nix/store/00000000000000000000000000000000-gone/etc/zshenv "$dirty_etc/zshenv"
    printf 'ssl-cert-file = %s\n' "$dirty_etc/ssl/certs/ca-bundle.crt" > "$dirty_etc/nix/nix.conf"
    : > "$dirty_etc/ssl/certs/ca-bundle.crt"
    printf 'UUID=DEAD-BEEF /nix apfs rw,noauto,nobrowse,nosuid,noatime\n' > "$dirty_etc/fstab"
    _ATYRODE_TEST_ETC_ROOT="$dirty_etc" atyrode doctor system macbook --json \
      > "$TMPDIR/darwin-residue.out" && {
      echo 'bootstrap residue did not fail diagnostics' >&2
      exit 1
    }
    jq -e '(.checks[] | select(.id == "bootstrap-residue")) as $c
      | $c.status == "incomplete"
      and $c.code == "bootstrap-residue"
      and ($c.actual.shellProfileBackups | index("'"$dirty_etc"'/bashrc"))
      and ($c.actual.unrecognisedProfiles | index("'"$dirty_etc"'/zshrc"))
      and ($c.actual.staleEtcLinks | index("'"$dirty_etc"'/zshenv"))
      and ($c.actual.brokenTrustAnchors | index("'"$dirty_etc"'/ssl/certs/ca-bundle.crt"))
      and ($c.actual.staleFstabEntry == "'"$dirty_etc"'/fstab")
      and ($c.remediation | contains("bootstrap/install.sh plan --config macbook"))
    ' "$TMPDIR/darwin-residue.out" >/dev/null
    # A backup a completed install left identical to its target is not residue.
    cp "$dirty_etc/bashrc.backup-before-nix" "$dirty_etc/bashrc"
    rm -f "$dirty_etc/zshrc" "$dirty_etc/zshenv" "$dirty_etc/fstab"
    : > "$dirty_etc/nix/nix.conf"
    printf 'anchors\n' > "$dirty_etc/ssl/certs/ca-certificates.crt"
    _ATYRODE_TEST_ETC_ROOT="$dirty_etc" atyrode doctor system macbook --json \
      > "$TMPDIR/darwin-residue-clean.out"
    jq -e '(.checks[] | select(.id == "bootstrap-residue") | .status) == "ok"' \
      "$TMPDIR/darwin-residue-clean.out" >/dev/null

    darwin_missing_adb="$TMPDIR/darwin-missing-adb.json"
    jq '.device.adbAvailable = false' "$darwin_ready" > "$darwin_missing_adb"
    export _ATYRODE_TEST_SYSTEM_FIXTURE="$darwin_missing_adb"
    if atyrode doctor system macbook --json > "$TMPDIR/darwin-missing-adb.out"; then
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
    if atyrode doctor system macbook --json > "$TMPDIR/darwin-drift.out"; then
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
    if atyrode doctor system macbook --json > "$TMPDIR/darwin-probe-failure.out"; then
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

    # Homebrew drift detection must remain read-only, even with hostile
    # caller settings. A darwin fixture with no .homebrew key falls through
    # to the live branch, so HOMEBREW_BUNDLE_FILE and HOMEBREW_NO_AUTO_UPDATE
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
      atyrode doctor system macbook --json <<<'PROMPT-ANSWER')"
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
    mkdir "$out"
  ''
