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
   backend, and capabilities rendered in the plan panel.
2. `atyrode apply --dry-run` supplies the activation preview. Terminal control
   sequences and carriage-return progress updates are normalized before the
   output is rendered inside the changes viewport.

No activation occurs during startup. Pressing `a` or `enter` opens a confirmation
step; only `y` then runs the real `atyrode apply` in the terminal. `n` or `esc`
cancels confirmation, `r` refreshes the plan and preview, arrow keys or `j`/`k`
scroll the preview, and `q` exits.

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
