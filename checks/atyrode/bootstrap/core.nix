{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
  system = pkgs.stdenv.hostPlatform.system;
  fleetCache =
    (builtins.fromJSON (builtins.readFile ../../../fleet/system-boundary.json)).nix.fleetCache;
in
mkScenario "core" ''
  new_fixture plan
  export PATH="$managed_tools:$base_path"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/plan.out"
  grep -q '^Preflight passed' "$TMPDIR/plan.out"
  grep -q '^Plan' "$TMPDIR/plan.out"
  test ! -e "$FAKE_LOG"
  test ! -e "$XDG_STATE_HOME"
  expect_failure "$repo/bootstrap/install.sh"
  test ! -e "$FAKE_LOG"
  test ! -e "$XDG_STATE_HOME"

  # Production bootstrap ignores ambient test hooks, including an arbitrary
  # profile script that would otherwise be sourced before activation.
  cat > "$TMPDIR/poison-profile" <<'EOF'
  : > "$BOOTSTRAP_POISON_MARKER"
  EOF
  export BOOTSTRAP_POISON_MARKER="$TMPDIR/poison-profile-executed"
  BOOTSTRAP_NIX_PROFILE_SCRIPT="$TMPDIR/poison-profile" \
    bash "$bootstrap" plan --repo "$repo" --config "$host" >/dev/null
  test ! -e "$BOOTSTRAP_POISON_MARKER"

  # Rewritten rather than deleted. What this scenario actually proved was
  # hook gating on the mutating path - the poison-profile check above only
  # covers read-only `plan` - and its old evidence, a 69 exit naming the real
  # /etc/shells, was a side effect of bootstrap owning the login shell.
  # atyrode apply owns that now, so assert the property that survives: a
  # production apply ignores BOOTSTRAP_NIX_PROFILE_SCRIPT and runs to
  # completion. Linux only, because a production darwin apply would ignore
  # BOOTSTRAP_PROFILE_TARGET_ROOT too and repair the builder's real /etc.
  if [[ "$FAKE_SYSTEM" == *-linux ]]; then
    new_fixture production-hook-gating
    export PATH="$managed_tools:$base_path"
    BOOTSTRAP_NIX_PROFILE_SCRIPT="$TMPDIR/poison-profile" \
      bash "$bootstrap" apply --yes --repo "$repo" --config "$host" \
      > "$TMPDIR/production-hooks.out" 2> "$TMPDIR/production-hooks.err"
    test ! -e "$BOOTSTRAP_POISON_MARKER"
    test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
    test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
    # The same run proves the fleet cache is never load-bearing: the
    # sandbox's /etc is read-only, the enrolment is refused, and the apply
    # still converges with a warning that hands the line to doctor.
    grep -F 'could not write /etc/nix/nix.conf' "$TMPDIR/production-hooks.err" >/dev/null
  fi

  # Repository identity, every class of dirt, and revision state are conservative.
  "$real_git" -C "$repo" remote set-url origin https://example.invalid/not-dotfiles.git
  expect_failure "$repo/bootstrap/install.sh" preflight --repo "$repo" --config "$host"
  "$real_git" -C "$repo" remote set-url origin https://github.com/atyrode/dotfiles.git
  "$real_git" -C "$repo" config url.file:///tmp/untrusted/.insteadOf https://github.com/
  expect_failure "$repo/bootstrap/install.sh" preflight --repo "$repo" --config "$host"
  "$real_git" -C "$repo" config --unset-all url.file:///tmp/untrusted/.insteadOf
  printf 'untracked\n' > "$repo/untracked"
  expect_failure "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" --allow-dirty >/dev/null
  rm "$repo/untracked"
  printf 'changed\n' >> "$repo/flake.nix"
  "$real_git" -C "$repo" add flake.nix
  expect_failure "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host"
  "$real_git" -C "$repo" reset -q --hard HEAD
  printf 'local revision\n' > "$repo/local-revision"
  "$real_git" -C "$repo" add local-revision
  "$real_git" -C "$repo" commit -q -m local-revision
  expect_failure "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" --allow-non-main >/dev/null
  "$real_git" -C "$repo" reset -q --hard origin/main
  "$real_git" -C "$repo" switch -q -c fixture
  expect_failure "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" --allow-non-main >/dev/null
  "$real_git" -C "$repo" switch -q main
  "$real_git" -C "$repo" checkout -q --detach
  expect_failure "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" --allow-non-main >/dev/null

  # A failed source update never reaches activation or writes the marker.
  new_fixture network-failure
  export PATH="$managed_tools:$base_path"
  export FAKE_GIT_FETCH_FAIL=1
  expect_failure "$repo/bootstrap/install.sh" apply --yes --update --repo "$repo" --config "$host"
  test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
  test ! -e "$FAKE_LOG"
  test ! -e "$XDG_STATE_HOME"

  # A successful update re-enters the fetched bootstrap and activates it.
  new_fixture update-success
  export PATH="$managed_tools:$base_path"
  upstream="$TMPDIR/update-success/upstream"
  "$real_git" clone -q "$repo" "$upstream"
  "$real_git" -C "$upstream" config user.name fixture
  "$real_git" -C "$upstream" config user.email fixture@example.invalid
  printf 'updated\n' > "$upstream/update-marker"
  "$real_git" -C "$upstream" add update-marker
  "$real_git" -C "$upstream" commit -q -m update
  updated_revision="$("$real_git" -C "$upstream" rev-parse HEAD)"
  export FAKE_GIT_UPDATE_REPO="$upstream"
  "$repo/bootstrap/install.sh" apply --yes --update --repo "$repo" --config "$host" >/dev/null
  test "$("$real_git" -C "$repo" rev-parse HEAD)" = "$updated_revision"
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
  test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"

  # An unattended bootstrap must not turn an unsafe preview into an apply.
  for disruption_status in blocked unknown; do
    new_fixture "disruption-$disruption_status"
    export PATH="$managed_tools:$base_path"
    FAKE_DISRUPTION_STATUS="$disruption_status" \
      expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
    grep -F -- '--preview-json' "$FAKE_LOG" >/dev/null
    ! grep -qF -- '--expected-disruption' "$FAKE_LOG"
    test ! -e "$XDG_STATE_HOME/atyrode/dotfiles-config"
  done

  # A clean checkout parked on another branch is returned to main by the
  # same --update path instead of demanding a manual git checkout, and the
  # branch it left keeps every commit.
  new_fixture update-branch-return
  export PATH="$managed_tools:$base_path"
  upstream="$TMPDIR/update-branch-return/upstream"
  "$real_git" clone -q "$repo" "$upstream"
  "$real_git" -C "$upstream" config user.name fixture
  "$real_git" -C "$upstream" config user.email fixture@example.invalid
  printf 'updated\n' > "$upstream/update-marker"
  "$real_git" -C "$upstream" add update-marker
  "$real_git" -C "$upstream" commit -q -m update
  updated_revision="$("$real_git" -C "$upstream" rev-parse HEAD)"
  "$real_git" -C "$repo" checkout -q -b parked
  "$real_git" -C "$repo" commit -q --allow-empty -m 'local experiment'
  parked_revision="$("$real_git" -C "$repo" rev-parse HEAD)"
  export FAKE_GIT_UPDATE_REPO="$upstream"

  # Without --update the refusal still names the branch and moves nothing.
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F 'checkout is on parked, not main' "$TMPDIR/expected-failure.err" >/dev/null
  test "$("$real_git" -C "$repo" symbolic-ref --short HEAD)" = parked

  "$repo/bootstrap/install.sh" apply --yes --update --repo "$repo" --config "$host" \
    >/dev/null 2> "$TMPDIR/branch-return.err"
  grep -F 'moving the checkout from parked to main' "$TMPDIR/branch-return.err" >/dev/null
  test "$("$real_git" -C "$repo" symbolic-ref --short HEAD)" = main
  test "$("$real_git" -C "$repo" rev-parse HEAD)" = "$updated_revision"
  test "$("$real_git" -C "$repo" rev-parse parked)" = "$parked_revision"
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
  test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
  # The fast-forward may have rewritten install.sh, so the run continues under
  # the new copy. Silently, that reads as the plan and its confirmation simply
  # appearing twice, and the operator answers the same question with no idea
  # why it was asked again.
  grep -F 'Restarting bootstrap under the updated source' "$TMPDIR/branch-return.err" >/dev/null
  grep -F 'it prints its plan and asks again' "$TMPDIR/branch-return.err" >/dev/null
  grep -E '^\$ bash .*install\.sh apply --repo .* --config ' "$TMPDIR/branch-return.err" >/dev/null

  # Download and integrity failures cannot execute the unverified installer.
  new_fixture download-failure
  export PATH="$fresh_tools:$base_path"
  export FAKE_CURL_FAIL=1
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test ! -e "$FAKE_INSTALL_EXECUTED"
  grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

  new_fixture checksum-failure
  export PATH="$fresh_tools:$base_path"
  export FAKE_BAD_SHA=1
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test ! -e "$FAKE_INSTALL_EXECUTED"
  test ! -e "$HOME/.nix-profile/bin/nix"
  grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

  new_fixture partial-installer-failure
  export PATH="$fresh_tools:$base_path"
  export FAKE_INSTALLER_FAIL_AFTER_START=1
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test -e "$FAKE_INSTALL_EXECUTED"
  test ! -e "$HOME/.nix-profile/bin/nix"
  grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

  # An interrupted upstream install leaves `<rc>.backup-before-nix` files
  # that make every later attempt fail deep inside the installer. Bootstrap
  # repairs that itself rather than handing the operator instructions.
  new_fixture profile-backup-repair
  export PATH="$fresh_tools:$base_path"
  export BOOTSTRAP_PROFILE_TARGET_ROOT="$TMPDIR/profile-backup-repair/etcroot"
  etc="$BOOTSTRAP_PROFILE_TARGET_ROOT/etc"
  mkdir -p "$etc"

  # A backup identical to its target is what a completed install leaves
  # behind: never planned, never touched.
  printf 'settled\n' > "$etc/bash.bashrc"
  cp "$etc/bash.bashrc" "$etc/bash.bashrc.backup-before-nix"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/settled-plan.out"
  if grep -Fq 'Restore the pre-Nix shell rc file' "$TMPDIR/settled-plan.out"; then
    echo 'a settled backup was unexpectedly planned for restore' >&2
    exit 1
  fi

  # A deleted target and a target the interrupted install rewrote are both
  # planned, and plan still moves nothing.
  printf 'stock zshrc\n' > "$etc/zshrc.backup-before-nix"
  printf 'stock bashrc\n' > "$etc/bashrc.backup-before-nix"
  printf '# Nix\nstock bashrc\n' > "$etc/bashrc"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/repair-plan.out"
  grep -F 'Restore the pre-Nix shell rc file' "$TMPDIR/repair-plan.out" >/dev/null
  grep -F "$etc/zshrc" "$TMPDIR/repair-plan.out" >/dev/null
  grep -F "$etc/bashrc" "$TMPDIR/repair-plan.out" >/dev/null
  test -e "$etc/zshrc.backup-before-nix"
  test ! -e "$etc/zshrc"

  # apply restores both, keeps the rewritten file beside the restored
  # original instead of discarding it, and proceeds into the installer.
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" > "$TMPDIR/repair-apply.out"
  test "$(cat "$etc/zshrc")" = 'stock zshrc'
  test ! -e "$etc/zshrc.backup-before-nix"
  test "$(cat "$etc/bashrc")" = 'stock bashrc'
  test ! -e "$etc/bashrc.backup-before-nix"
  grep -Fxq '# Nix' "$etc/bashrc.nix-install-leftover"
  test "$(cat "$etc/bash.bashrc")" = settled
  test -e "$etc/bash.bashrc.backup-before-nix"
  grep -F "Restored $etc/zshrc" "$TMPDIR/repair-apply.out" >/dev/null
  test -e "$FAKE_INSTALL_EXECUTED"
  test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"

  # Standalone Linux is the one platform where no Nix layer owns the daemon's
  # nix.conf, so bootstrap enrols the fleet cache there itself: planned while
  # the file lacks it, appended below whatever the installer wrote, readable
  # by the unprivileged client, and settled - never planned again - once
  # present. Darwin never plans it because nix-darwin declares both caches.
  if [[ "$FAKE_SYSTEM" == *-linux ]]; then
    new_fixture fleet-cache-enrolment
    export PATH="$managed_tools:$base_path"
    export BOOTSTRAP_PROFILE_TARGET_ROOT="$TMPDIR/fleet-cache-enrolment/etcroot"
    etc="$BOOTSTRAP_PROFILE_TARGET_ROOT/etc"
    mkdir -p "$etc/nix"
    printf 'build-users-group = nixbld\n' > "$etc/nix/nix.conf"
    "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/fleet-cache-plan.out"
    grep -F 'Enrol the Nix daemon in the fleet binary cache' "$TMPDIR/fleet-cache-plan.out" >/dev/null
    grep -F '${fleetCache.substituter}' "$TMPDIR/fleet-cache-plan.out" >/dev/null
    test "$(cat "$etc/nix/nix.conf")" = 'build-users-group = nixbld'
    "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" > "$TMPDIR/fleet-cache-apply.out"
    grep -F "Enrolled the fleet binary cache in $etc/nix/nix.conf" "$TMPDIR/fleet-cache-apply.out" >/dev/null
    test "$(sed -n 1p "$etc/nix/nix.conf")" = 'build-users-group = nixbld'
    grep -Fxq 'extra-substituters = ${fleetCache.substituter}' "$etc/nix/nix.conf"
    grep -Fxq 'extra-trusted-public-keys = ${fleetCache.trustedPublicKey}' "$etc/nix/nix.conf"
    test "$(stat -c %a "$etc/nix/nix.conf")" = 644
    test "$(wc -l < "$etc/nix/nix.conf")" -eq 3
    grep -F 'enrolled the fleet cache' "$XDG_STATE_HOME/atyrode/bootstrap/repairs/undo.log" >/dev/null
    "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/fleet-cache-settled.out"
    if grep -Fq 'Enrol the Nix daemon' "$TMPDIR/fleet-cache-settled.out"; then
      echo 'an enrolled daemon was unexpectedly planned for enrolment again' >&2
      exit 1
    fi
    # A fresh single-user machine has no /etc/nix at all; bootstrap creates
    # it rather than treating the absence as somebody else's.
    rm -rf "$etc/nix"
    "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
    test "$(wc -l < "$etc/nix/nix.conf")" -eq 2
    grep -Fxq 'extra-substituters = ${fleetCache.substituter}' "$etc/nix/nix.conf"
  fi

  # Fresh installation verifies the artifact, activates, verifies, and remains
  # idempotent on a repeated upgrade-style invocation.
  new_fixture fresh-success
  export PATH="$fresh_tools:$base_path"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" > "$TMPDIR/fresh.out"
  grep -F "exec $FAKE_EXPECTED_LOGIN_SHELL -l" "$TMPDIR/fresh.out" >/dev/null
  if grep -F 'exec zsh -l' "$TMPDIR/fresh.out" >/dev/null; then
    echo 'bootstrap emitted a PATH-dependent shell handoff' >&2
    exit 1
  fi
  test -e "$FAKE_INSTALL_EXECUTED"
  test "$(cat "$FAKE_INSTALL_ARGS")" = "$FAKE_EXPECTED_INSTALL_ARGS"
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
  test "$(readlink "$HOME/.zshrc")" = /nix/store/fixture-home-manager-files/.zshrc
  test "$(readlink "$HOME/.zshenv")" = /nix/store/fixture-home-manager-files/.zshenv
  "$repo/bootstrap/install.sh" verify --repo "$repo" --config "$host" >/dev/null
  CODER_WORKSPACE_NAME=fixture \
    CODER_AGENT_URL=https://coder.example.invalid \
    FAKE_GH_AUTH=1 \
    "$repo/bootstrap/install.sh" >/dev/null
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "development-${system}"
  grep -F -- "--git-auth-mode https-gh" "$FAKE_LOG" >/dev/null
  test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"

  # A failed activation leaves the interrupted-apply marker naming the
  # attempted configuration; the prior host state is untouched.
  new_fixture activation-failure
  export PATH="$managed_tools:$base_path"
  mkdir -p "$XDG_STATE_HOME/atyrode"
  printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
  export FAKE_ACTIVATION_FAIL=1
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
  grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

  # A post-activation verification failure also leaves the marker instead of
  # being mistaken for success.
  new_fixture verification-failure
  export PATH="$managed_tools:$base_path"
  mkdir -p "$XDG_STATE_HOME/atyrode"
  printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
  export FAKE_VERIFY_FAIL=1
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -Fxq "config=$host" "$XDG_STATE_HOME/atyrode/install-interrupted"

  # Doctor's 69 is the opposite of the scenario above, and telling them apart
  # is the whole point: the machine activated, the receipt matches, and what
  # remains is drift that a later `atyrode apply` converges or that only the
  # operator can decide. Bootstrap therefore completes -- marker cleared, exit
  # zero -- and says what was found. Reported as a failure it became
  # [BOOT-E399], which sends the operator to the issue tracker and offers to
  # reset a Nix installation that was never broken.
  new_fixture doctor-findings-finish-the-bootstrap
  export PATH="$managed_tools:$base_path"
  export FAKE_DOCTOR_FINDINGS=1
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" \
    > "$TMPDIR/findings.out" 2> "$TMPDIR/findings.err"
  # On the operator's own stream, not inside the captured verification step:
  # a call to action that only a transcript ever sees is not a call to action.
  grep -qF 'Bootstrap complete, with findings for' "$TMPDIR/findings.out"
  grep -qF 'atyrode doctor' "$TMPDIR/findings.out"
  grep -qF 'exec ' "$TMPDIR/findings.out"
  # The two states this scenario exists to keep apart.
  ! grep -qF 'BOOT-E399' "$TMPDIR/findings.out" "$TMPDIR/findings.err"
  ! grep -qF 'recover --config' "$TMPDIR/findings.out" "$TMPDIR/findings.err"
  # An apply that finished must not look interrupted to the next run.
  test ! -e "$XDG_STATE_HOME/atyrode/install-interrupted"
  unset FAKE_DOCTOR_FINDINGS

  # Every command that changes the machine is printed before it runs. A
  # bootstrap that mutates a machine silently is one an operator cannot audit
  # while it happens or reproduce afterwards, and the argv is shell-quoted so
  # the line can be pasted back verbatim.
  new_fixture bootstrap-shows-the-commands-it-runs
  export PATH="$managed_tools:$base_path"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" \
    > "$TMPDIR/visible.out" 2> "$TMPDIR/visible.err"
  # Either stream: a captured step replays its transcript on stdout, a
  # streamed one writes straight to stderr, and the operator reads both.
  cat "$TMPDIR/visible.out" "$TMPDIR/visible.err" > "$TMPDIR/visible.all"
  grep -qF "\$ nix run $repo#atyrode -- apply $host" "$TMPDIR/visible.all"
  grep -qF "\$ nix run $repo#atyrode -- doctor $host" "$TMPDIR/visible.all"

  # State and marker namespaces may not redirect writes through symlinks.
  new_fixture state-root-link
  export PATH="$managed_tools:$base_path"
  mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode"
  ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/bootstrap"
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

  new_fixture atyrode-state-link
  export PATH="$managed_tools:$base_path"
  mkdir -p "$HOME/redirect" "$XDG_STATE_HOME"
  ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode"
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

  new_fixture interrupted-marker-link
  export PATH="$managed_tools:$base_path"
  mkdir -p "$HOME/redirect" "$XDG_STATE_HOME/atyrode"
  ln -s "$HOME/redirect" "$XDG_STATE_HOME/atyrode/install-interrupted"
  expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  test -z "$(find "$HOME/redirect" -mindepth 1 -print -quit)"

  # An abrupt interruption leaves the marker naming the attempted
  # configuration, plan warns about it without clearing it, and a
  # subsequent successful apply removes it.
  new_fixture interrupted
  export PATH="$managed_tools:$base_path"
  mkdir -p "$XDG_STATE_HOME/atyrode"
  printf 'sentinel\n' > "$XDG_STATE_HOME/atyrode/dotfiles-config"
  if BOOTSTRAP_FAILPOINT=before-activation \
    "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null 2>&1; then
    echo 'interruption failpoint unexpectedly succeeded' >&2
    exit 1
  fi
  marker="$XDG_STATE_HOME/atyrode/install-interrupted"
  test -f "$marker"
  grep -Fxq "config=$host" "$marker"
  grep -Eq '^started=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker"
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = sentinel
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" \
    > "$TMPDIR/interrupted-plan.out" 2> "$TMPDIR/interrupted-plan.err"
  grep -F "previous apply of $host" "$TMPDIR/interrupted-plan.err" >/dev/null
  grep -F "re-run: ./bootstrap/install.sh apply --config $host" \
    "$TMPDIR/interrupted-plan.err" >/dev/null
  test -f "$marker"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  test ! -e "$marker"
  test "$(cat "$XDG_STATE_HOME/atyrode/dotfiles-config")" = "$host"
''
