{
  lib,
  pkgs,
  atyrode,
}:

let
  fixtures = import ../lib/omp-fixtures.nix { inherit lib pkgs; };
  applyFixtures = import ../lib/atyrode-fixtures.nix { inherit pkgs; };
  config = fixtures.evalAgentTools pkgs { ompPackage = pkgs.omp-configured; };
  activation = pkgs.writeShellScript "babel-analysis-activation" config.home.activation.migrateBabelAnalysisRuntime.data;
  # This caller predates the transition. Rebuilding today's apply with an old
  # version label would not catch a migration accidentally placed in apply itself.
  previous = builtins.getFlake "github:atyrode/dotfiles/acbb36b1e2a01b56a5eea7b390bf61eb2d02ddc3";
  oldAtyrode = previous.packages.${pkgs.stdenv.hostPlatform.system}.atyrode.override {
    enableTestHooks = true;
  };
  generation = pkgs.runCommand "native-analysis-home-manager-generation" { } ''
    mkdir -p "$out/home-files/.config/systemd/user"
    ln -s ${activation} "$out/activate"
  '';
  profile = builtins.toJSON {
    id = "existing-profile";
    revision = 2;
    selection = {
      local = "fixture-model";
      thinking = "minimal";
    };
    combo_id = "local_fixture-model";
    disclosure = "local";
    redaction_required = false;
    cost = {
      currency = "USD";
      input_per_1k = 0;
      output_per_1k = 0;
      estimated_run = 0;
    };
    metadata = {
      lane = "local";
      provider = "local";
      model = "fixture-model";
      thinking = "minimal";
      combo = "local_fixture-model";
      engine = "lm-studio";
      endpoint = "http://127.0.0.1:1";
      cost_basis = "synthetic offline migration fixture";
    };
    saved = 1700000000;
  };
in
pkgs.runCommand "check-babel-analysis-migration"
  {
    nativeBuildInputs = [
      pkgs.babel
      pkgs.code
      pkgs.jq
      atyrode
    ];
  }
  ''
    ${applyFixtures.base}
    ${applyFixtures.gitNh}
    ${applyFixtures.identity}
    trap 'echo "migration check failed at line $LINENO: $BASH_COMMAND" >&2' ERR
    export _ATYRODE_TEST_SYSTEM=${pkgs.stdenv.hostPlatform.system}
    profile_name=development-${pkgs.stdenv.hostPlatform.system}
    jq -n --arg id "$profile_name" '{id:$id}' > "$XDG_CONFIG_HOME/atyrode/host.json"

    # Unconfigured machines acquire neither a profile nor an analysis setting.
    ${activation}
    test ! -e "$XDG_CONFIG_HOME/babel/analysis.json"
    test ! -e "$XDG_STATE_HOME/code/profiles"

    legacy="$XDG_STATE_HOME/code/babel/profiles/existing-profile"
    mkdir -p "$legacy" "$XDG_CONFIG_HOME/babel" "$HOME/managed/bin" "$HOME/old-login/bin"
    printf '%s\n' ${lib.escapeShellArg profile} > "$legacy/00000002.json"
    jq '.revision = 1' "$legacy/00000002.json" > "$legacy/00000001.json"
    chmod 600 "$legacy"/*.json

    # The wrapper is an operator choice. It permits describe only, so an
    # accidental model-backed check fails even without a reachable provider.
    { printf '#!%s\n' '${pkgs.runtimeShell}'; printf '%s\n' \
      '[[ "$1" == engine && "$2" == --describe ]] || exit 95' \
      'export CODE_AUTH_ACCOUNT_STATE="$HOME/account-choice"' \
      'printf "%s\\n" "$*" >> "$HOME/wrapper-calls"' \
      'exec "$HOME/managed/bin/code" "$@"';
    } > "$HOME/worker-wrapper"
    chmod +x "$HOME/worker-wrapper"
    ln -s "$HOME/old-login/bin/code" "$HOME/managed/bin/code"
    jq -n --arg worker "$HOME/worker-wrapper" '{schema:1,worker:$worker,worker_args:["babel"],
      profile:{id:"existing-profile",revision:2,configured_at:"2026-01-01T00:00:00Z",extension:{keep:true}},
      titles:{worker:"code",worker_args:["babel"],
        profile:"existing-profile",revision:1,configured_at:"2026-01-01T00:00:00Z",
        future_title:{keep:true}},
      future:{preserve:"unchanged"}}' > "$XDG_CONFIG_HOME/babel/analysis.json"
    cp "$XDG_CONFIG_HOME/babel/analysis.json" "$TMPDIR/before.json"
    if babel analysis migrate --check --json > "$TMPDIR/pending.json"; then
      echo 'legacy launch was incorrectly declared ready' >&2; exit 1
    fi
    jq -e '.needed and (.changed | not) and .configured == 2' "$TMPDIR/pending.json" >/dev/null
    atyrode doctor provisioning --json > "$TMPDIR/pending-doctor.json" || true
    jq -e '.surfaces[] | select(.id == "babel-analysis") |
      .status == "degraded" and .code == "migration-needed"' "$TMPDIR/pending-doctor.json" >/dev/null
    test ! -e "$HOME/wrapper-calls"
    DRY_RUN=1 ${activation}
    cmp "$TMPDIR/before.json" "$XDG_CONFIG_HOME/babel/analysis.json"
    test ! -e "$XDG_STATE_HOME/code/profiles"

    # The incoming shell still knows old tools. The target activation must use
    # its own package paths, not whichever Babel/Code that shell resolves.
    for command in babel code; do
      { printf '#!%s\n' '${pkgs.runtimeShell}'; printf 'exit 96\n'; } > "$HOME/old-login/bin/$command"
      chmod +x "$HOME/old-login/bin/$command"
    done
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      { printf '#!%s\n' '${pkgs.runtimeShell}'; printf '%s\n' \
        '[[ "$1 $2" == "home switch" ]] || exit 97' \
        'ln -sfn ${pkgs.omp-configured}/bin/code "$HOME/managed/bin/code"' \
        'exec "$3/activate"';
      } > "$TMPDIR/bin/activate-nh"
      chmod +x "$TMPDIR/bin/activate-nh"
      PATH="$HOME/old-login/bin:$PATH" ATYRODE_NH="$TMPDIR/bin/activate-nh" \
        ${oldAtyrode}/bin/atyrode apply "$profile_name" --candidate ${generation} --json \
        > "$TMPDIR/apply.out" 2> "$TMPDIR/apply.err" || {
          cat "$TMPDIR/apply.out" "$TMPDIR/apply.err" >&2; exit 1;
        }
    ''}
    ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      ln -sfn ${pkgs.omp-configured}/bin/code "$HOME/managed/bin/code"
      PATH="$HOME/old-login/bin:$PATH" ${activation}
    ''}
    for revision in 00000001 00000002; do
      cmp "$legacy/$revision.json" "$XDG_STATE_HOME/code/profiles/existing-profile/$revision.json"
    done
    jq '.worker_args=[] | .titles.worker_args=[]' "$TMPDIR/before.json" > "$TMPDIR/expected.json"
    jq -S . "$TMPDIR/expected.json" > "$TMPDIR/expected.sorted"
    jq -S . "$XDG_CONFIG_HOME/babel/analysis.json" > "$TMPDIR/actual.sorted"
    cmp "$TMPDIR/expected.sorted" "$TMPDIR/actual.sorted"
    test -s "$HOME/wrapper-calls"
    babel analysis migrate --check --json | jq -e '(.needed | not) and (.changed | not) and .configured == 2' >/dev/null
    cp "$XDG_CONFIG_HOME/babel/analysis.json" "$TMPDIR/after.json"
    ${activation}
    cmp "$TMPDIR/after.json" "$XDG_CONFIG_HOME/babel/analysis.json"

    atyrode doctor provisioning --json > "$TMPDIR/doctor.json" || true
    jq -e '.surfaces[] | select(.id == "babel-analysis") | .status == "ok"' "$TMPDIR/doctor.json" >/dev/null

    # A collision must stop activation before settings are rewritten, not turn
    # a recorded profile reference into a different selection under the same ID.
    cp "$TMPDIR/before.json" "$XDG_CONFIG_HOME/babel/analysis.json"
    target="$XDG_STATE_HOME/code/profiles/existing-profile/00000002.json"
    jq '.selection.thinking="high"' "$target" > "$TMPDIR/conflicting.json"
    cp "$TMPDIR/conflicting.json" "$target"
    if ${activation} > "$TMPDIR/conflict.out" 2>&1; then
      echo 'conflicting profile revision was overwritten' >&2; exit 1
    fi
    cmp "$TMPDIR/conflicting.json" "$target"
    cmp "$TMPDIR/before.json" "$XDG_CONFIG_HOME/babel/analysis.json"
    cmp ${pkgs.writeText "original-profile.json" (profile + "\n")} "$legacy/00000002.json"
    mkdir "$out"
  ''
