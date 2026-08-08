{ pkgs }:

# Regression tests for the comparison logic of scripts/docs-drift-guard.sh
# (the docs-only CI fast path invariant, #169). The eval mode needs a git
# repository and network for flake inputs, so only the pure --compare mode
# is testable in the sandbox; the eval mode is exercised by the docs-links
# CI job on every docs-only pull request.
pkgs.runCommand "check-docs-drift-guard"
  {
    nativeBuildInputs = [ pkgs.jq ];
    guard = ../scripts/docs-drift-guard.sh;
  }
  ''
    write() { printf '%s' "$2" > "$1"; }

    base='{
      "x86_64-linux": {"docs-links": "/nix/store/aaa-docs-links.drv", "production-facts": "/nix/store/aab-production-facts.drv", "agent-tools": "/nix/store/bbb-agent-tools.drv"},
      "aarch64-linux": {"agent-tools": "/nix/store/ccc-agent-tools.drv"},
      "aarch64-darwin": {"darwin-evaluation": "/nix/store/ddd-darwin.drv"}
    }'
    write base.json "$base"

    expect_pass() {
      bash "$guard" --compare base.json "$1" \
        || { echo "FAIL: expected pass for $1"; exit 1; }
    }
    expect_fail() {
      local report
      if report="$(bash "$guard" --compare base.json "$1" 2>&1)"; then
        echo "FAIL: expected drift failure for $1"; exit 1
      fi
      echo "$report" | grep -qF "$2" \
        || { echo "FAIL: drift report for $1 missing '$2': $report"; exit 1; }
    }

    # Identical snapshots: clean.
    write identical.json "$base"
    expect_pass identical.json

    # Only the intentional whole-tree lints drift (docs-links and
    # production-facts scan documentation on purpose): clean.
    write lints-only.json "$(jq '.["x86_64-linux"]["docs-links"] = "/nix/store/zzz-docs-links.drv"
      | .["x86_64-linux"]["production-facts"] = "/nix/store/zzz-production-facts.drv"' <<< "$base")"
    expect_pass lints-only.json

    # A non-docs derivation drifts on the lint platform: blocked.
    write x86-drift.json "$(jq '.["x86_64-linux"]["agent-tools"] = "/nix/store/zzz-agent-tools.drv"' <<< "$base")"
    expect_fail x86-drift.json "x86_64-linux.agent-tools"

    # Drift on a platform whose matrix leg would be skipped: blocked.
    write darwin-drift.json "$(jq '.["aarch64-darwin"]["darwin-evaluation"] = "/nix/store/zzz-darwin.drv"' <<< "$base")"
    expect_fail darwin-drift.json "aarch64-darwin.darwin-evaluation"

    # A check appearing or disappearing is drift too.
    write added-check.json "$(jq '.["aarch64-linux"]["new-check"] = "/nix/store/eee-new.drv"' <<< "$base")"
    expect_fail added-check.json "aarch64-linux.new-check"
    write removed-check.json "$(jq 'del(.["aarch64-linux"]["agent-tools"])' <<< "$base")"
    expect_fail removed-check.json "aarch64-linux.agent-tools"

    mkdir "$out"
  ''
