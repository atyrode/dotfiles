# atyrode-tui

Interactive Bubble Tea cockpit for the scriptable `atyrode` Bash CLI. It uses
`cli-kit` for the shared palette and layout primitives, and delegates every
operation to the existing CLI rather than reimplementing activation logic.

## Entry behavior

- Bare `atyrode` with stdin and stdout attached to a TTY opens the cockpit.
- Any subcommand continues through the Bash CLI unchanged.
- Bare non-TTY invocation continues to print CLI help.

The wrapper exports `ATYRODE_CLI` before launching the cockpit. The TUI uses
that exact executable for plan, preview, apply, and Ask grounding, so packaged
and checkout-specific behavior remain aligned.

## Apply panel

Startup runs only `atyrode apply --plan --json`. That command supplies the host,
system, immutable target revision, backend, and active capabilities rendered in
the plan panel; remote plans include the full commit as `resolvedRevision`.
Once the plan is validated, apply confirmation is immediately available.

The expensive read-only inspections are opt-in so a constrained host never
starts multiple Nix evaluations merely by opening the cockpit:

- Press `v` to start `atyrode apply --ref <resolvedRevision> --preview-json`.
  It runs the same read-only `nh … --dry` preview and returns the stable schema
  described below. Press `v` again to cancel it.
- Press `c` (or `Tab`) to open capabilities and lazily start
  `atyrode inventory --ref <resolvedRevision> --json`.

Preview and inventory requests never overlap. Their subprocess groups are
cancelled on refresh, quit, or apply, and stale replies are ignored. A failed
optional inspection stays local to its panel and never disables the validated
apply plan.

No activation occurs during startup or inspection. Pressing `a` or `enter`
opens a confirmation step; only `y` then runs
`atyrode apply --ref <resolvedRevision>` in the terminal. The preview,
inventory, and activation therefore address the same immutable commit even if
the published branch advances while the cockpit is open. `n` or `esc` cancels
confirmation, `r` resolves the branch again, arrow keys or `j`/`k` scroll the
focused pane, and `d` toggles normalized technical details after a preview is
loaded. Press `c` to open or focus capabilities and `c`/`esc` to return to the
preview without resetting either pane.

## Capability panel

Capabilities appear in the apply plan's declared active order. The selected
view shows `Title  n/N`, textual active/applicable state, resolved item count,
purpose, deliverables grouped by kind, and delivery, system, security, and
mutable-state boundaries. Deliberate marker capabilities such as `server`
explicitly say that they have no direct deliverables. Descriptions lead each
item; name, version, source, and delivery are secondary.

Use `[`/`]` or left/right arrows to cycle backward and forward with wrapping.
On wide terminals the activation preview remains beside a 42-cell capability
panel; `Tab` moves scrolling focus between them. Medium terminals open a
full-width capability view, while narrow terminals stack the selection summary
over a safely wrapped, scrollable detail list. Selection and both independent
scroll positions survive `c`, `esc`, focus changes, and the Ask overlay.

The parser accepts inventory schema version 1 only, requires the manifest's
full revision and system to equal the apply plan, derives the platform from that
system, and resolves the planned host through its canonical id or aliases.
Loading, command failures, and identity/schema mismatches remain visible as
text inside the capability view. They never substitute stale inventory and
never change preview or confirmation state.

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

This package owns the apply cockpit from issue #110, its read-only Ask panel
from issue #117, and the capability inventory panel from issue #196. Follow-up
operational panels remain separate:

- issue #111: generations, rollback, and clean;
- issue #112: doctor and remaining operational read panels.

## Verification

`nix build .#atyrode-tui` runs the focused Go tests. They cover plan, preview,
and exact-revision inventory command sequencing; schema and identity
validation; active order; cycling and focus; independent scroll preservation;
grouping, empty markers, long text, platform state, loading and failure safety;
explicit apply confirmation; responsive 140-, 100-, 72-, and 44-column
layouts; CLI-derived Ask grounding; streaming; and cancellation. Visual changes
also follow `docs/tui-verification.md`: capture the app in tmux under the
truecolor environment, verify PUA codepoints and row bounds from the character
grid, and inspect `freeze` renders.
