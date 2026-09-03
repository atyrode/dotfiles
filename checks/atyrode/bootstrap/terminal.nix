{ pkgs }:

let
  inherit (import ./harness.nix { inherit pkgs; }) mkScenario;
in
mkScenario "terminal" ''
  # Capturing a managed step costs the conversation it was holding: the CLI
  # gates sudo, the vault, and every provisioning offer on stdin and stdout
  # both being a terminal. Where one is present bootstrap must hand the step
  # its own stdio and write no transcript, and the run log must say so, since
  # that file is the account of where the output went.
  new_fixture managed-step-streams-on-a-terminal
  export PATH="$managed_tools:$base_path"
  export BOOTSTRAP_TEST_TTY=1
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  log="$(find "$XDG_STATE_HOME/atyrode/bootstrap/logs" -name '*-apply.log' -print -quit)"
  grep -F 'activation streamed to the operator terminal' "$log" >/dev/null
  test ! -e "''${log%.log}-activation.log"

  # The same failure still gets a code without a transcript to read: the
  # states that classify from machine state are exactly the ones a terminal
  # cannot take away. The anchor is unowned so the sweep leaves it, which
  # makes activation the first step to trip over it.
  darwin_fixture managed-step-streams-and-still-classifies
  export PATH="$managed_tools:$base_path"
  export BOOTSTRAP_TEST_TTY=1
  mkdir -p "$etc/ssl/certs" "$HOME/.nix-profile/bin"
  ln -s /opt/elsewhere/ca.crt "$etc/ssl/certs/ca-certificates.crt"
  FAKE_ACTIVATION_FAIL=1 \
    expect_failure "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host"
  grep -F '[BOOT-E302]' "$TMPDIR/expected-failure.err" >/dev/null
  log="$(find "$XDG_STATE_HOME/atyrode/bootstrap/logs" -name '*-apply.log' -print -quit)"
  test ! -e "''${log%.log}-activation.log"
  unset FAKE_ACTIVATION_FAIL

  # Without a terminal the transcript is the only account of the step, so it
  # is written and the classifier reads it. This is the contract the E303
  # scenarios above depend on; assert it directly rather than by their proxy.
  new_fixture managed-step-captures-without-a-terminal
  export PATH="$managed_tools:$base_path"
  "$repo/bootstrap/install.sh" apply --yes --repo "$repo" --config "$host" >/dev/null
  log="$(find "$XDG_STATE_HOME/atyrode/bootstrap/logs" -name '*-apply.log' -print -quit)"
  test -f "''${log%.log}-activation.log"
  grep -F 'Verification passed' "''${log%.log}-verification.log" >/dev/null

  # Colour is a reading aid, never data. Every assertion in this file greps
  # plain text, and every operator who redirects a run reads plain text, so
  # the invariant is that a non-terminal run emits no escape byte at all.
  new_fixture plan-emits-no-escapes-off-a-terminal
  export PATH="$managed_tools:$base_path"
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/plain.out" 2>&1
  grep -F 'Preflight passed' "$TMPDIR/plain.out" >/dev/null
  ! grep -q "$(printf '\033')" "$TMPDIR/plain.out"

  # And that the painting is real when a terminal is present, so the plain
  # case above is evidence of the gate rather than of dead code.
  new_fixture plan-paints-on-a-terminal
  export PATH="$managed_tools:$base_path"
  export BOOTSTRAP_TEST_COLOR=1
  "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" > "$TMPDIR/painted.out" 2>&1
  grep -q "$(printf '\033')" "$TMPDIR/painted.out"
  grep -F "$(printf '\033[1;32mPreflight passed\033[0m')" "$TMPDIR/painted.out" >/dev/null

  # NO_COLOR is honoured even where the stream would allow colour: it is the
  # operator's decision, not the terminal's.
  new_fixture no-color-is-honoured
  export PATH="$managed_tools:$base_path"
  NO_COLOR=1 "$repo/bootstrap/install.sh" plan --repo "$repo" --config "$host" \
    > "$TMPDIR/nocolor.out" 2>&1
  ! grep -q "$(printf '\033')" "$TMPDIR/nocolor.out"
''
