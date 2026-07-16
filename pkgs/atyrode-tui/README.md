# atyrode-tui

Interactive Bubble Tea cockpit for the scriptable `atyrode` Bash CLI. It inherits
shared panel chrome, persistent workspace navigation, clipped lists, palette,
and PromptBox behavior from `cli-kit`, while delegating every operation to the
existing CLI rather than reimplementing activation or lifecycle policy.

## Entry behavior

- Bare `atyrode` with stdin and stdout attached to a TTY opens the cockpit on
  its neutral Overview workspace.
- Opening Overview performs no Apply evaluation or mutation.
- Any subcommand continues through the Bash CLI unchanged.
- Bare non-TTY invocation continues to print CLI help.

The wrapper exports `ATYRODE_CLI` before launching the cockpit. The TUI uses
that exact executable for every JSON report, preview, confirmed mutation, and
Ask grounding, so packaged and checkout-specific behavior remain aligned.

## Overview and navigation

Overview explains the cockpit and lists every workspace without preallocating
empty panel height. The top navigation is an aligned responsive grid of numbered
titles (`1. Overview` through `6. Ask`); only the selected cell's background
moves. `Tab` and `Shift+Tab` cycle persistent workspaces, while `1`–`6` jump
directly. Local loading, selection, scroll, preview, and confirmation state
survives round trips between workspaces. Narrow and medium layouts wrap the
complete grid and shorten controls without entering the terminal auto-wrap
column.

## Apply panel

The first visit to Apply runs only `atyrode apply --plan --json`. That command
supplies the host, system, immutable target revision, backend, and active
capabilities rendered in the plan panel; remote plans include the full commit
as `resolvedRevision`. Once validated, confirmation is immediately available.

The expensive read-only inspections remain opt-in:

- Press `v` to start `atyrode apply --ref <resolvedRevision> --preview-json`.
  Press `v` again to cancel it.
- Press `c` to focus capabilities and lazily start
  `atyrode inventory --ref <resolvedRevision> --json`.

Preview and inventory requests never overlap. Their subprocess groups are
cancelled on refresh, quit, or apply, and stale replies are ignored. A failed
optional inspection stays local to its panel and never disables the validated
apply plan.

No activation occurs during startup or inspection. Pressing `a` or `enter`
opens a confirmation step; only `y` then runs
`atyrode apply --ref <resolvedRevision>`. `n` or `esc` cancels, `r` resolves the
branch again, arrow keys or `j`/`k` scroll the focused pane, and `d` toggles
normalized technical details after a preview is loaded.

## Capability workspace

The standalone Capabilities workspace reuses the same exact-revision inventory
authority as Apply. Before Apply resolves an identity it explains that
dependency; afterwards it lazily loads and retains the validated inventory.

Capabilities appear in the Apply plan's declared active order. The selected
view shows `Title  n/N`, textual active/applicable state, resolved item count,
purpose, deliverables grouped by kind, and delivery, system, security, and
mutable-state boundaries. Use `[`/`]` or left/right arrows to cycle. Apply uses
`c` to move focus between preview and capability panes; global `Tab` remains
workspace navigation.

The parser accepts inventory schema version 1 only, requires the manifest's
full revision and system to equal the Apply plan, derives the platform from that
system, and resolves the planned host through its canonical id or aliases.
Failures remain local and never substitute stale inventory or change Apply
confirmation state.

## Doctor workspace

Doctor renders the existing `doctor host`, `doctor system`, and `doctor tools`
JSON contracts as three lazy tabs. Valid reports remain visible when the CLI
returns a semantic nonzero status, so host mismatches, incomplete system checks,
and missing expected tools are diagnostics rather than transport failures.
Malformed or absent JSON remains a local report error. Refresh, cancellation,
and generation-scoped stale-reply rejection match the existing inspection
behavior.

## Generations / Clean workspace

The lifecycle workspace lists `generations --json --sizes`, marks the current
generation, and keeps rollback and cleanup behind preview-first confirmation:

- rollback runs `rollback --to N --dry-run`, displays the exact target, then
  requires `y` before `rollback --to N --yes`;
- cleanup opens a policy editor for every `atyrode clean` capability: keep
  count, keep-since duration, user or all-profile scope (`--all`), and verbose
  planning (`--verbose`);
- `Ctrl+X` selects maximum reclaim (`--keep 0 --keep-since 0d`), which still
  retains the current generation;
- Enter runs the exact configured policy through `clean --dry-run --json`,
  validates that the returned scope and retention values match, and displays
  every candidate before `y` forwards the same policy with `--yes`.

JSON stdout is decoded separately from progress and diagnostics on stderr. The
current generation cannot be selected for rollback, cancellation before
confirmation performs no mutation, and a confirmed lifecycle mutation cannot
be cancelled or left until its authoritative command result is reported.

## Ask panel

Press `ctrl+o` to open the read-only Ask panel and ask a question about
`atyrode`. The panel uses `cli-kit`'s `PromptBox` with the OMP Asker backend and
streams the answer in place. On the first question it derives its grounding
directly from `atyrode --help`, caches that command reference, and instructs the
backend not to invent undocumented commands or flags. It does not expose Act
mode, typed actions, or any command-execution path.

Press `esc` or `ctrl+o` to close the panel. Either key cancels an in-flight
request, and opening or closing the panel does not reset the apply plan,
preview, selection, details mode, or confirmation state.

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

This package owns the Apply cockpit from #110, Ask from #117, exact-revision
capabilities from #196, the Overview/navigation shell from #215,
Generations/Clean from #111, and Doctor/read panels from #112.

## Verification

`nix build .#atyrode-tui` runs focused Go tests covering navigation and lazy
Apply entry; state retention; exact-revision preview and inventory; Doctor
semantic nonzero reports, malformed JSON, cancellation, and stale replies;
rollback preview/confirmation; Clean policy propagation and cancellation;
explicit Apply confirmation; and responsive 150-, 100-, 80-, 72-, and
44-column layouts.

Visual changes follow `docs/tui-verification.md`: drive the packaged cockpit in
tmux under the truecolor environment, verify exact PUA codepoints and row bounds
from the character grid, and inspect `freeze` PNG renders.
