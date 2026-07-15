# atyrode-tui

Interactive Bubble Tea cockpit for the scriptable `atyrode` Bash CLI. It uses
`cli-kit` for the shared palette and layout primitives, and delegates every
operation to the existing CLI rather than reimplementing activation logic.

## Entry behavior

- Bare `atyrode` with stdin and stdout attached to a TTY opens the cockpit.
- Any subcommand continues through the Bash CLI unchanged.
- Bare non-TTY invocation continues to print CLI help.

The wrapper exports `ATYRODE_CLI` before launching the cockpit. The TUI uses
that exact executable for plan, preview, and apply commands, so packaged and
checkout-specific behavior remain aligned.

## Apply panel

Startup performs two read-only operations in order:

1. `atyrode apply --plan --json` supplies the host, system, target revision,
   backend, and capabilities rendered in the plan panel. Remote plans include
   the full commit as `resolvedRevision`.
2. `atyrode apply --ref <resolvedRevision> --preview-json` runs the same
   read-only `nh … --dry` preview and returns the stable schema described below.
   The TUI renders that structure rather than parsing terminal text.

No activation occurs during startup. Pressing `a` or `enter` opens a confirmation
step; only `y` then runs `atyrode apply --ref <resolvedRevision>` in the terminal.
The preview and activation therefore address the same immutable commit even if
the published branch advances while the cockpit is open. `n` or `esc` cancels
confirmation, `r` resolves and previews the branch again, arrow keys or `j`/`k`
scroll the preview, `d` toggles between the operator summary and normalized
technical details, and `q` exits.

## Preview JSON contract

`atyrode apply --preview-json` is additive; existing plain output, `--plan
--json`, and `--dry-run` behavior remain unchanged. The command emits one JSON
document with `schemaVersion: 1`, the host/system/full resolved revision, a
duration-free `status`, package changes grouped as `added`, `updated`, and
`removed`, and only the store-path, closure-size, and generation facts reported
by `nh`. Each package retains its granular `changeKind` (`added`, `removed`,
`upgraded`, `downgraded`, or `changed`) plus available versions and size delta.
`technical` contains the normalized diff report without spinner-frame history.

`nh` 4.4.1 does not expose this report as JSON. The separate
`atyrode-preview-parser` executable owns the nh-to-schema conversion and is
covered with fixtures for every current dix change kind, totals, generation
paths, no-change output, terminal controls, and format drift. Unknown package
status lines fail closed instead of silently dropping a change. Version 1 may
gain optional fields; removing or changing field meaning requires incrementing
`schemaVersion`. The TUI rejects unknown versions and rejects a preview whose
host, system, or full revision differs from the plan.

## Scope

This package currently owns only the apply cockpit from issue #110. Follow-up
panels remain separate:

- issue #111: generations, rollback, and clean;
- issue #112: doctor, capabilities, and package inventory;
- issue #117: the read-only Ask panel.

## Verification

`nix build .#atyrode-tui` runs the Go tests. The tests cover plan/preview command
sequencing, explicit confirmation, failure safety, terminal-output normalization,
responsive panel borders, capability layout, and narrow-window overflow. Visual
changes should also follow `docs/tui-verification.md`: capture the app in tmux at
representative sizes and inspect a truecolor ANSI render with `freeze`.
