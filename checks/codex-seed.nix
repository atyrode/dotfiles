{ pkgs }:

# Exercises the one-time Codex config seed: it installs the curated defaults
# once, backs up (never merges) a pre-existing config.toml so machine-local
# project trust survives, and is idempotent afterward (the file becomes the
# user's). Uses a deterministic fixture seed instead of the packaged default.
pkgs.runCommand "check-codex-seed"
  {
    nativeBuildInputs = [
      pkgs.codex-seed
      pkgs.gnugrep
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    fail() {
      echo "FAIL: $1" >&2
      exit 1
    }

    seed="$TMPDIR/seed.toml"
    cat >"$seed" <<'TOML'
    model = "gpt-5.5"
    model_reasoning_effort = "xhigh"

    [tui]
    theme = "catppuccin-frappe"
    TOML
    export CODEX_SEED_FILE="$seed"

    # Scenario: dry run on a pristine machine writes nothing at all.
    export HOME="$TMPDIR/pristine"
    mkdir -p "$HOME"
    AGENT_TOOLS_DRY_RUN=1 atyrode-codex-seed apply >"$TMPDIR/dry.log" 2>&1
    grep -qi 'DRY RUN' "$TMPDIR/dry.log" || fail "pristine dry run was not announced"
    [ ! -e "$HOME/.codex" ] || fail "dry run created ~/.codex"
    [ ! -e "$HOME/.local/state/atyrode/codex-seed" ] || fail "dry run created state"

    # Scenario: first boot with no config.toml — install the seed, mode 600.
    export HOME="$TMPDIR/firstboot"
    mkdir -p "$HOME"
    atyrode-codex-seed apply >"$TMPDIR/first.log" 2>&1
    config="$HOME/.codex/config.toml"
    [ -f "$config" ] || fail "first boot did not create config.toml"
    [ "$(stat -c '%a' "$config")" = "600" ] || fail "config mode is not 600"
    grep -q 'model = "gpt-5.5"' "$config" || fail "first boot did not install the seed"
    [ -e "$HOME/.local/state/atyrode/codex-seed/seeded" ] || fail "marker not set"

    # status --json reports the seeded state.
    atyrode-codex-seed status --json >"$TMPDIR/status.json" 2>&1
    grep -q '"seeded":true' "$TMPDIR/status.json" || fail "status did not report seeded"

    # A pre-existing config.toml with machine-local [projects] trust is backed
    # up (never merged), replaced by the seed, and preserved in the backup.
    export HOME="$TMPDIR/existing"
    mkdir -p "$HOME/.codex"
    config="$HOME/.codex/config.toml"
    cat >"$config" <<'TOML'
    model = "operator-custom"

    [projects."/home/alex/secret"]
    trust_level = "trusted"
    TOML
    atyrode-codex-seed apply >"$TMPDIR/existing.log" 2>&1
    grep -q 'model = "gpt-5.5"' "$config" || fail "existing config was not reseeded"
    ! grep -q 'operator-custom' "$config" || fail "pre-existing config was not replaced"
    backup="$(ls "$HOME/.codex/"config.toml.pre-seed.* 2>/dev/null | head -1 || true)"
    [ -n "$backup" ] && [ -f "$backup" ] || fail "existing config was not backed up"
    grep -q 'trust_level = "trusted"' "$backup" || fail "project trust not preserved in backup"

    # Scenario: idempotent — a second apply is a no-op even after a local edit,
    # because the seed is one-time (the file is now the user's).
    echo 'model = "user-choice"' >"$config"
    atyrode-codex-seed apply >"$TMPDIR/idem.log" 2>&1
    grep -qi 'already seeded' "$TMPDIR/idem.log" || fail "re-run did not detect the marker"
    grep -q 'model = "user-choice"' "$config" || fail "idempotent re-run clobbered a local edit"

    mkdir "$out"
  ''
