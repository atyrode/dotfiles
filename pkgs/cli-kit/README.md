# cli-kit

The shared visual layer + Bubble Tea components for the dotfiles' custom CLIs, so
every tool (`code`, `atyrode`, …) looks and feels like it came from the same dev.
Consumed as a local Go module via `replace cli-kit => ../cli-kit`.

## What's here

- **Palette & styles** (`palette.go`) — colour tokens (`CAcc`, `CBord`, …), the
  `MeterRamp`, text-presentation glyphs (`GWarn`/`GBroken`/`GReset`), and shared
  lipgloss styles (`StDim`, `StHead`, …).
- **Layout and section helpers** (`layout.go`, `meter.go`) —
  `PadLeft`/`Pad`, `WindowList` (a clipped, scrollbar'd column), `Scrollbar`,
  meters, and full-width `Rule`/`SeparatedSections` boundaries. Widths are
  terminal cells; empty sections produce no orphan rule.
- **Footer conventions** (`palette.go`, `layout.go`) — `NewHelp` applies the
  shared key/description/separator palette to Bubble Help, while `WrapHelp`
  wraps complete required cues without dropping them. Both remain ANSI-aware
  through lipgloss width measurement.
- **The smart PromptBox** (`promptbox.go`) + the **consumer contract**
  (`contract.go`, `run.go`) + an **omp backend** (`ompasker.go`).

## The consumer contract

A CLI built on cli-kit is a Bubble Tea model (`tea.Model`). It launches through
`clikit.Run`, which mounts capabilities the model **opts into** by implementing
small interfaces — structural, compile-time, à la carte:

| Implement | Get |
|---|---|
| *(nothing extra)* | palette + layout + the footer/help conventions |
| `Askable` → `Asker() Asker` | the PromptBox in **Ask** mode (read-only Q&A) |
| `Commandable` → `Commander() Commander` | the PromptBox in **Act** mode (propose → diff → confirm) |
| `Documented` → `Docs() DocCorpus` | grounding injected into the backend's system prompt |

`clikit.Run(app)` detects what's implemented and mounts the box behind a toggle
key (default `ctrl+o`). The same key or `esc` closes it and cancels any in-flight
request. Act mode takes precedence over Ask when both are present.

### Ask mode

```go
type helpApp struct{ /* your tea.Model */ }

func (helpApp) Asker() clikit.Asker { return clikit.NewOmpAsker(myDocs) }
func (helpApp) Docs() clikit.DocCorpus { return myDocs }

func main() { _, _ = clikit.Run(helpApp{...}, clikit.WithAltScreen()) }
```

`NewOmpAsker` shells out to a headless omp run
(`omp -p --mode text --no-session --no-tools --model claude-haiku-4-5
--append-system-prompt <docs> <prompt>`) and streams the answer; dismissing the
box kills the omp subprocess. Set `OmpAsker.ReplaceSystem` for a narrow grounded
assistant that must replace the coding-agent prompt and managed scaffolding.
Override the evaluator via `OmpAsker.Model`.

### Act mode

Implement `Commander`; its `Actions(ctx, prompt)` returns a closed set of
`Action{Key, Value}` the box shows for confirmation. On accept the host receives a
`clikit.ActionsConfirmedMsg` (forwarded to your model's `Update`) — apply the
actions through the **same code path as a manual change**. The closed action set
*is* your tool's agent-facing API surface.

## Design

The rationale, the runtime-mutation wall, phasing, and open questions live in
[`DESIGN-promptbox.md`](./DESIGN-promptbox.md). `code` is the reference consumer.

## Building / testing

`cli-kit` is a checked flake package: `nix build .#cli-kit` runs the unit tests in
`checkPhase`. Note the vendoring coupling — `code-tui` includes `../cli-kit` in
its build source, so a change to any `cli-kit/*.go` shifts `code-tui`'s
`vendorHash` (bump it; see the comment in `pkgs/code-tui/default.nix`).
