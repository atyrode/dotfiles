{ atyrode, pkgs }:

let
  fixtures = import ./lib/atyrode-fixtures.nix { inherit pkgs; };
in
pkgs.runCommand "check-atyrode-lifecycle"
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
    chmod +x "$TMPDIR/bin/nix-env" "$TMPDIR/bin/omp"
    export ATYRODE_NIX_ENV="$TMPDIR/bin/nix-env"
    mkdir -p "$XDG_STATE_HOME/nix/profiles"
    touch "$XDG_STATE_HOME/nix/profiles/home-manager"
    export ATYRODE_GEN_PROFILE="$XDG_STATE_HOME/nix/profiles/home-manager"
    # Exercise the packaged local-qwen lease/reaper lifecycle state machine.
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      ${pkgs.runtimeShell} ${./test-data/local-qwen-lifecycle.sh} ${atyrode}/libexec/atyrode-runtime
    ''}
    # store-lifecycle guards (#21): cleanup must never be an implicit side effect
    # of apply. A structural scan on purpose — it proves the property for EVERY
    # path through apply_config, which no single apply invocation can. The
    # retention window, the rollback refusal, and the clean/rollback/generations
    # dispatch are asserted behaviourally below (on nh's actual argv and on the
    # CLI's own output) rather than on the wording of the source.
    if awk '/^apply_config\(\) \{/{f=1} f&&/cmd_clean|cmd_rollback/{print; hit=1} /^\}/{if(f)f=0} END{exit hit?0:1}' \
      ${import ./lib/atyrode-source.nix { inherit pkgs; }}; then
      echo 'apply invokes cleanup/rollback implicitly' >&2
      exit 1
    fi
    # ATYRODE_GIT / ATYRODE_NH are honoured only under test hooks. That seam is
    # asserted behaviourally in checks/atyrode-apply.nix: a stub reachable only
    # through the env var IS used by this test-hooks build, and a production
    # build refuses the command instead of driving the real git/nh.

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

    # A bare clean keeps a rollback window: 5 generations plus everything newer
    # than 30d (#21), so the current generation and the configured rollback set
    # can never be destroyed. Pinned on the retention nh is actually asked for.
    rm -f "$TMPDIR/nh-args"
    default_retention="$(atyrode clean --yes 2>&1 >/dev/null)"
    grep -qxF 'clean user --keep 5 --keep-since 30d --no-gc' "$TMPDIR/nh-args" \
      || { echo "bare clean must ask nh for the default retention window: $(cat "$TMPDIR/nh-args")" >&2; exit 1; }
    grep -qF 'keeping 5 generation(s) + everything newer than 30d' <<<"$default_retention" \
      || { echo "bare clean must state the default retention window: $default_retention" >&2; exit 1; }
    # The retention nh is asked for is also the retention an operator can read.
    # A confirm answers "may I"; only the argv answers "with what", and this is
    # the command that removes generations.
    grep -qF '$ ' <<<"$default_retention" \
      || { echo "clean must show the command it runs: $default_retention" >&2; exit 1; }
    grep -qE '^\$ .*clean user --keep 5 --keep-since 30d --no-gc$' <<<"$default_retention" \
      || { echo "clean must announce nh's full argv: $default_retention" >&2; exit 1; }

    # rollback refuses the generation that is already current (#3 in the stub
    # listing), so the running configuration can't be rolled onto itself.
    set +e
    rollback_current="$(atyrode rollback --to 3 --yes 2>&1 >/dev/null)"
    rollback_current_status="$?"
    set -e
    test "$rollback_current_status" = 64 \
      || { echo "rollback onto the current generation must be refused (exit $rollback_current_status): $rollback_current" >&2; exit 1; }
    grep -qF 'generation 3 is already current' <<<"$rollback_current" \
      || { echo "rollback refusal must name the current generation: $rollback_current" >&2; exit 1; }

    # clean/rollback/generations are dispatched to their implementations, not
    # reserved: each reaches real behaviour instead of dying "reserved for a
    # follow-up issue" (clean is exercised throughout this check).
    atyrode generations --json | jq -e \
      'length == 3 and ([.[] | select(.current)] | map(.generation) == [3])' >/dev/null \
      || { echo 'generations must report the stub profile listing' >&2; exit 1; }
    rollback_previous="$(atyrode rollback --dry-run --yes 2>&1 >/dev/null)"
    grep -qF 'back from generation 3 to 2' <<<"$rollback_previous" \
      || { echo "rollback must default to the previous generation: $rollback_previous" >&2; exit 1; }
    grep -qF 'dry run — nothing activated' <<<"$rollback_previous" \
      || { echo "rollback --dry-run must not activate anything: $rollback_previous" >&2; exit 1; }

    # A real rollback re-runs activation, which is the same class of change
    # apply makes -- and apply shows its argv. The dry run above deliberately
    # activates nothing, so it can prove the refusal but never this.
    mkdir -p "$ATYRODE_GEN_PROFILE-2-link"
    {
      printf '#!%s\n' "${pkgs.runtimeShell}"
      printf 'printf %s\n' "'rolled back'"
    } > "$ATYRODE_GEN_PROFILE-2-link/activate"
    chmod +x "$ATYRODE_GEN_PROFILE-2-link/activate"
    rollback_real="$(atyrode rollback --to 2 --yes 2>&1 >/dev/null)"
    grep -qE '^\$ .*/home-manager-2-link/activate$' <<<"$rollback_real" \
      || { echo "rollback must announce the activation it runs: $rollback_real" >&2; exit 1; }
    grep -qF 'now on generation 2' <<<"$rollback_real" \
      || { echo "rollback must confirm the generation it landed on: $rollback_real" >&2; exit 1; }

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

    mkdir "$out"
  ''
