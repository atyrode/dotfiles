{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
in
mkScenario "darwin-codes-recover" ''
  # An upstream installer failure is classified into a code that names the
  # repair, and an unrecognised one reports the transcript instead of a
  # bare exit status.
  darwin_fixture darwin-installer-failure-codes
  export PATH="$fresh_tools:$base_path"
  FAKE_INSTALLER_FAIL_MESSAGE='touch: /etc/bashrc: No such file or directory' \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E201]' "$TMPDIR/expected-failure.err" >/dev/null
  FAKE_INSTALLER_FAIL_MESSAGE='something nobody has seen before' \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E299]' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F 'nix-installer.log' "$TMPDIR/expected-failure.err" >/dev/null

  # A managed step runs Nix, so it fails whenever Nix cannot reach the cache.
  # A dangling CA bundle is the state that causes it, and it is re-derived at
  # failure time rather than parsed out of the error prose.
  darwin_fixture darwin-managed-step-codes
  export PATH="$managed_tools:$base_path"
  mkdir -p "$etc/ssl/certs" "$HOME/.nix-profile/bin"
  # Not owned by this toolchain, so the sweep correctly leaves it in place
  # and activation is the first thing to trip over it.
  ln -s /opt/elsewhere/ca.crt "$etc/ssl/certs/ca-certificates.crt"
  FAKE_ACTIVATION_FAIL=1 \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E302]' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F "$etc/ssl/certs/ca-certificates.crt" "$TMPDIR/expected-failure.err" >/dev/null
  test -L "$etc/ssl/certs/ca-certificates.crt"

  # The same state, but owned: verify runs no repairs, so it is the phase
  # that can still meet a stale link and must name it rather than exit bare.
  rm "$etc/ssl/certs/ca-certificates.crt"
  ln -s /nix/store/0000000000000000000000000000000-etc/ca.crt \
    "$etc/ssl/certs/ca-certificates.crt"
  expect_failure "$repo/bootstrap/install.sh" verify --repo "$repo" --config "$host"
  grep -F '[BOOT-E301]' "$TMPDIR/expected-failure.err" >/dev/null

  # No CA problem: the failure is unrecognised, says so with the log, and
  # names the exit so an unclassified state is never a dead end.
  rm "$etc/ssl/certs/ca-certificates.crt"
  FAKE_ACTIVATION_FAIL=1 \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E399]' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F '  log: ' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F "./bootstrap/install.sh recover --config $host" "$TMPDIR/expected-failure.err" >/dev/null

  # A configuration that fails to build is not a broken machine. This landed
  # in the unrecognised bucket and offered to reset a perfectly healthy Nix
  # installation -- the same wrong remedy the doctor-69 case above already
  # had to be taught once, reached by a different route.
  FAKE_BUILD_FAIL=1 \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E304]' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F 'darwin-system-26.11' "$TMPDIR/expected-failure.err" >/dev/null
  grep -F 'this machine is unchanged' "$TMPDIR/expected-failure.err" >/dev/null
  ! grep -qF './bootstrap/install.sh recover' "$TMPDIR/expected-failure.err"

  # Recovery is the exit for a state with no repair. It resets what a dead
  # generation owns - the daemon, /etc/nix, the store volume - and installs
  # Nix fresh, without deleting anything it cannot put back.
  darwin_fixture darwin-recover
  export PATH="$managed_tools:$base_path"
  export FAKE_LAUNCHCTL_LOG="$TMPDIR/darwin-recover/launchctl.log"
  plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
  mkdir -p "$(dirname "$plist")" "$etc/nix"
  printf '<dict><key>Label</key><string>org.nixos.nix-daemon</string></dict>\n' > "$plist"
  printf 'ssl-cert-file = %s/ssl/certs/ca-certificates.crt\n' "$etc" > "$etc/nix/nix.conf"
  printf 'Nix Store\tdisk3s7\tLIVE-UUID\n' > "$FAKE_VOLUMES"
  mkdir -p "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db"
  : > "$BOOTSTRAP_PROFILE_TARGET_ROOT/nix/var/nix/db/db.sqlite"
  # Recovery is destructive enough to require saying so out loud: it prints
  # the plan, then refuses to touch anything without an explicit answer.
  if "$repo/bootstrap/install.sh" recover --repo "$repo" --config "$host" \
    > "$TMPDIR/recover-plan.out" 2> "$TMPDIR/recover-plan.err"; then
    echo 'recover proceeded without confirmation' >&2
    exit 1
  fi
  grep -F 'Recovery plan' "$TMPDIR/recover-plan.out" >/dev/null
  grep -F 'nothing on it is deleted' "$TMPDIR/recover-plan.out" >/dev/null
  grep -F 'requires an interactive terminal' "$TMPDIR/recover-plan.err" >/dev/null
  # Nothing moved: a live install is still exactly as it was.
  test -f "$plist"
  test -f "$etc/nix/nix.conf"
  test ! -e "$FAKE_INSTALL_EXECUTED"

  "$repo/bootstrap/install.sh" recover --yes --repo "$repo" --config "$host" >/dev/null
  grep -Fx 'system/org.nixos.nix-daemon' "$FAKE_LAUNCHCTL_LOG" >/dev/null
  test ! -e "$plist"
  test ! -e "$etc/nix"
  # Renamed, not deleted: same device, same UUID, and the data is still there.
  grep -E "^Nix Store \(orphaned [0-9TZ]+\)	disk3s7	LIVE-UUID	" "$FAKE_VOLUMES" >/dev/null
  # Nix was present, and recovery reinstalls it anyway - that is the point.
  test -e "$FAKE_INSTALL_EXECUTED"
  # An undo command is only worth the file it restores from, so assert the
  # archive exists and still holds what was removed.
  repairs="$XDG_STATE_HOME/atyrode/bootstrap/repairs"
  undo="$repairs/undo.log"
  grep -F "cp '$repairs/nix-daemon.plist." "$undo" >/dev/null
  grep -F 'org.nixos.nix-daemon' \
    "$(find "$repairs" -name 'nix-daemon.plist.*' -print -quit)" >/dev/null
  grep -F "removed $etc/nix" "$undo" >/dev/null
  grep -F 'ssl-cert-file' \
    "$(find "$repairs" -name 'etc-nix.*' -print -quit)/nix.conf" >/dev/null
  grep -F "diskutil rename 'disk3s7' 'Nix Store'" "$undo" >/dev/null
  unset FAKE_LAUNCHCTL_LOG

  # An already-unloaded daemon is the state recovery converges on, so a
  # non-zero bootout must not fail the run.
  darwin_fixture darwin-recover-unloaded-daemon
  export PATH="$managed_tools:$base_path"
  export FAKE_LAUNCHCTL_LOADED=0
  plist="$BOOTSTRAP_PROFILE_TARGET_ROOT/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
  mkdir -p "$(dirname "$plist")"
  printf '<dict/>\n' > "$plist"
  : > "$FAKE_VOLUMES"
  "$repo/bootstrap/install.sh" recover --yes --repo "$repo" --config "$host" >/dev/null
  test ! -e "$plist"
  unset FAKE_LAUNCHCTL_LOADED

  # On Linux the managed environment lives in /nix, so removing it is
  # destruction rather than recovery, and recovery refuses by name. The
  # platform is forced rather than inherited from the runner: taking it from
  # uname would assert nothing on the macOS job, which is the one job where
  # recovery is reachable.
  new_fixture recover-refuses-on-linux
  export PATH="$managed_tools:$base_path"
  export BOOTSTRAP_FORCE_SYSTEM=x86_64-linux
  expect_failure "$repo/bootstrap/install.sh" recover --yes --repo "$repo" --config "$host"
  grep -F 'is not a recovery' "$TMPDIR/expected-failure.err" >/dev/null
''
