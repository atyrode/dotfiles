{ atyrode, pkgs }:

let
  fixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
in
pkgs.runCommand "check-atyrode-generations"
  {
    nativeBuildInputs = [
      atyrode
      pkgs.jq
    ];
  }
  ''
    ${fixtures.base}
    ${fixtures.gitNh}
    ${fixtures.identity}
    # Stub nix-env's generation listing (rollback reads it).
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
    chmod +x "$TMPDIR/bin/nix-env"
    export ATYRODE_NIX_ENV="$TMPDIR/bin/nix-env"
    mkdir -p "$XDG_STATE_HOME/nix/profiles"
    touch "$XDG_STATE_HOME/nix/profiles/home-manager"
    export ATYRODE_GEN_PROFILE="$XDG_STATE_HOME/nix/profiles/home-manager"
    ln -s "$ATYRODE_TEST_CANDIDATE" "$ATYRODE_GEN_PROFILE-2-link"
    # Exercise the packaged local-qwen lease/reaper lifecycle state machine.
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      ${pkgs.runtimeShell} ${../fixtures/local-qwen-lifecycle.sh} ${atyrode}/libexec/atyrode-runtime
    ''}
    # ATYRODE_GIT / ATYRODE_NH are honoured only under test hooks. That seam is
    # asserted behaviourally in checks/atyrode/atyrode-apply.nix: a stub reachable only
    # through the env var IS used by this test-hooks build, and a production
    # build refuses the command instead of driving the real git/nh.

    # clean is nh clean under this machine's activation. The fixture host is
    # standalone Home Manager, so nh cleans the user's profiles; a bare run asks
    # nh for the default rollback window (5 generations plus everything newer
    # than 30d, #21) and leaves the store collection to nh, so the current
    # generation and the configured rollback set can never be destroyed. Pinned
    # on the argv nh is actually given, and on the announcement: a confirm
    # answers "may I", only the argv answers "with what".
    rm -f "$TMPDIR/nh-args"
    default_retention="$(atyrode clean --yes 2>&1 >/dev/null)"
    grep -qxF 'clean user --keep 5 --keep-since 30d' "$TMPDIR/nh-args" \
      || { echo "bare clean must ask nh for the default retention window: $(cat "$TMPDIR/nh-args")" >&2; exit 1; }
    grep -qE '^\$ .*clean user --keep 5 --keep-since 30d$' <<<"$default_retention" \
      || { echo "clean must announce nh's full argv: $default_retention" >&2; exit 1; }
    # Without --yes the confirmation is nh's own, in front of nh's plan; a dry
    # run is nh's dry run and has nothing to ask.
    atyrode clean --keep 3 --keep-since 7d >/dev/null 2>&1
    grep -qxF 'clean user --keep 3 --keep-since 7d --ask' "$TMPDIR/nh-args" \
      || { echo "clean without --yes must leave the confirmation to nh: $(cat "$TMPDIR/nh-args")" >&2; exit 1; }
    atyrode clean --dry-run >/dev/null 2>&1
    grep -qxF 'clean user --keep 5 --keep-since 30d --dry' "$TMPDIR/nh-args" \
      || { echo "a dry clean must be nh's dry run and ask nothing: $(cat "$TMPDIR/nh-args")" >&2; exit 1; }
    # A system activation owns every profile on the machine, and nh elevates
    # for that itself.
    ATYRODE_HOST=dev-01 atyrode clean --dry-run >/dev/null 2>&1
    grep -qxF 'clean all --keep 5 --keep-since 30d --dry' "$TMPDIR/nh-args" \
      || { echo "a NixOS host must clean every profile: $(cat "$TMPDIR/nh-args")" >&2; exit 1; }
    # nh's failure is clean's failure, carried with nh's own exit status rather
    # than dressed up as a success or a different error.
    set +e
    ATYRODE_NH_FAIL=1 atyrode clean --yes >/dev/null 2>&1
    clean_fail_status="$?"
    set -e
    test "$clean_fail_status" = 1 \
      || { echo "clean must exit with nh's status when nh fails (exit $clean_fail_status)" >&2; exit 1; }

    # rollback refuses the generation that is already current (#3 in the stub
    # listing) as a usage error, so the running configuration can't be rolled
    # onto itself.
    set +e
    rollback_current="$(atyrode rollback --to 3 --yes 2>&1 >/dev/null)"
    rollback_current_status="$?"
    set -e
    test "$rollback_current_status" = 64 \
      || { echo "rollback onto the current generation must be refused (exit $rollback_current_status): $rollback_current" >&2; exit 1; }

    # rollback is dispatched to its implementation, not reserved: it reaches
    # real behaviour instead of dying "reserved for a follow-up issue". The
    # only generation link the fixture places is #2, so a dry run that exits
    # zero has resolved the previous generation and nothing else; and a dry
    # run never announces the activation, because it never runs one.
    set +e
    rollback_previous="$(atyrode rollback --dry-run --yes 2>&1 >/dev/null)"
    rollback_previous_status="$?"
    set -e
    test "$rollback_previous_status" = 0 \
      || { echo "rollback must default to the previous generation (exit $rollback_previous_status): $rollback_previous" >&2; exit 1; }
    ! grep -qF "$ATYRODE_TEST_CANDIDATE/activate" <<<"$rollback_previous" \
      || { echo "rollback --dry-run must not activate anything: $rollback_previous" >&2; exit 1; }

    # A real rollback re-runs activation, which is the same class of change
    # apply makes -- and apply shows its argv. The dry run above deliberately
    # activates nothing, so it can prove the refusal but never this.
    #
    # Linux only, because the generation profile a rollback activates is chosen
    # from the real `uname`: this fixture pins the profile path but not the
    # platform, and on Darwin the same command correctly resolves to
    # darwin-rebuild and refuses without one. The branch it does exercise is
    # the one standalone Linux actually rolls back through.
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      rollback_real="$(atyrode rollback --to 2 --yes 2>&1 >/dev/null)"
      grep -qF "$ATYRODE_TEST_CANDIDATE/activate" <<<"$rollback_real" \
        || { echo "rollback must announce the activation it runs: $rollback_real" >&2; exit 1; }
    ''}

    # Colour is opt-in on the outcome: forced on it wraps the announced command
    # in SGR codes, and by default (no tty, no override) the output stays
    # byte-plain so pipes and this harness read clean text. \033 is the ESC that
    # opens every SGR sequence.
    color_out="$(_ATYRODE_TEST_COLOR=1 atyrode clean --keep 3 --yes 2>&1)"
    printf '%s' "$color_out" | grep -q "$(printf '\033')" \
      || { echo 'forced colour must emit ANSI SGR codes' >&2; exit 1; }
    plain_out="$(atyrode clean --keep 3 --yes 2>&1)"
    printf '%s' "$plain_out" | grep -q "$(printf '\033')" \
      && { echo 'default (non-tty) output must stay plain — no ANSI codes' >&2; exit 1; }

    mkdir "$out"
  ''
