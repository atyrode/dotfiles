# cli-kit: PromptBox + the consumer contract (design proposal)

> **Status: proposal for review — not frozen.** Tracks #115 (PromptBox), #120
> (consumer contract), #121 (cli-kit tracker). This documents the *shape* a CLI
> adopts to build on `cli-kit` and light up any of its capabilities without
> bespoke plumbing. It deliberately does **not** commit the code yet — per #107's
> principle, the interfaces land *with* their first real usage and are validated
> by two consumers (`code` + `atyrode`) before being codified. Open questions for
> the operator are collected at the end.

## Goal

A CLI built on `cli-kit` should get, for free and by a single convention:

- the shared palette + layout + footer/help conventions (already true today), and
- a **smart PromptBox** — type a prompt → agent "thinks" → streamed answer — that
  can either **Ask** (read-only Q&A about the tool) or **Act** (propose changes to
  the tool's own state), depending only on which capabilities the tool opts into.

The box UI is generic and lives in `cli-kit`. What's tool-specific (its docs, its
answer backend, its set of allowed actions) is injected by the host through small
interfaces. No tool re-implements the box; no tool-specific knowledge leaks into
`cli-kit`.

## The contract

### Baseline

Every `cli-kit` TUI already is a Bubble Tea model that uses the shared palette and
footer helpers. Nothing new is required for a tool that wants only that.

### Opt-in capability interfaces

A host opts into a capability by implementing its interface. Go's structural
typing means this is **compile-time, additive, and à-la-carte** — a tool
implements only what it offers, and mis-implementing a claimed capability fails to
build. (This mechanism is validated — see "Validation" below.)

```go
// Asker answers a prompt read-only, streaming tokens and closing the channel when
// done. ctx cancellation MUST kill the underlying work (e.g. the omp subprocess).
type Asker interface {
	Ask(ctx context.Context, prompt string) (<-chan string, error)
}

// Action is one host-validated mutation the agent may propose (Act mode).
type Action struct{ Key, Value string }

// Commander turns a prompt into a closed set of typed actions the host applies.
// This closed set IS the tool's agent-facing API surface.
type Commander interface {
	Actions(ctx context.Context, prompt string) ([]Action, error)
}

// DocCorpus is grounding text injected into the Ask system prompt.
type DocCorpus string

// The opt-in capabilities a host App may implement:
type Askable     interface{ Asker() Asker }
type Commandable interface{ Commander() Commander }
type Documented  interface{ Docs() DocCorpus }
```

### The runner

`clikit.Run(app)` wraps `tea.NewProgram`, applies the footer/help conventions, and
mounts capabilities by detecting which interfaces `app` implements:

- implements `Askable` → the PromptBox overlay + its keybinding are mounted;
- implements `Documented` → its corpus grounds every Ask;
- implements `Commandable` → the box also offers **Act** (propose → diff → confirm).

A tool that implements none still runs with palette + layout + footer. One
entrypoint; capabilities auto-detected, never wired by hand.

## Flows

### Ask (read-only — ship first)

1. Host opens the box (keybinding). User types, submits.
2. Box enters the "thinking" state (reuse the shared spinner).
3. Box calls `Asker.Ask(ctx, prompt)`; the backend injects `Documented.Docs()` (if
   any) into the system prompt and streams tokens into the answer viewport.
4. **esc cancels**: cancelling `ctx` kills the backend work, not just the UI.

Ask is safe, stateless, and the first thing to build — it exercises the whole
box + backend + grounding pipeline with none of Act's risk.

### Act (mutation — second)

1–3 as above, but the backend returns `[]Action` instead of prose.
4. The host **validates** the actions against its own rules and renders them as a
   **diff against current state**, applied through the *same code path as a manual
   change*. For `code` an Action is `{facet, value}` applied to `m.sel` exactly as
   the ←→ keys do — so the agent can only do what the user could do by hand.
5. **Tune or accept.** Accept applies; the existing reset-to-defaults key (`d` in
   `code`, PR #119) is the natural **undo**.

#### Why Act needs a typed channel (the runtime-mutation wall)

A running Bubble Tea program's state lives in the Go process's memory. A
shelled-out agent can edit files on disk but **cannot reach into a live TUI's
selections**. So "let the agent run bash to change the tool" works only for
tools whose state is on disk; a live picker like `code` requires this minimal
typed action channel the TUI validates and applies. Docs-in-prompt is how the
agent *decides*; the typed Action is how it *applies*. The two are complementary,
not alternatives.

## Onboarding a new CLI

1. Build the TUI as a Bubble Tea model using the `cli-kit` palette/footer helpers.
2. Hand it to `clikit.Run`.
3. Implement `Documented` to answer questions; `Askable` to get the box; add
   `Commandable` when you want the agent to drive the tool. Implement only what
   you need — each is independent.

## How the contract is "enforced" (layered, weakest → strongest)

1. **Doc** — this file + a `cli-kit` README section describing the contract.
2. **Compile-time interfaces** — the capability interfaces above; structural, so
   nothing is forced on a tool that doesn't want a capability.
3. **Reference consumer** — `code` is the proven extraction source and canonical
   example the doc points at; `atyrode` is the second validator.
4. **(optional, later)** a blessed skeleton/example a new tool copies — only worth
   it once a third tool appears.

Recommendation: land (1)–(3); defer (4).

## Validation

The capability-detection mechanism (the part with real design risk) was
pressure-tested in standalone Go: three sample hosts — one opting into
Ask+Act+Docs, one into Ask+Docs only, one into nothing — all type-check as valid
Apps, detection via type assertions behaves, and a stubbed streaming `Asker` with
`ctx` cancellation runs. The shape holds; only the real backend + widget wiring
remain (and those are gated on the open questions below).

## Open questions for the operator

1. **`cli-kit` gains a Bubble Tea dependency.** Today `cli-kit` is lipgloss-only;
   its components are pure renderers and the `tea.Program` lives in each consumer.
   A `PromptBox` with `Update(tea.Msg)` and a `clikit.Run` runner make `cli-kit`
   Bubble-Tea-aware. Reasonable for a shared TUI kit, but it's a deliberate
   widening of `cli-kit`'s remit — approve the direction, or keep the box as a
   consumer-side component that only borrows `cli-kit`'s interfaces + palette?
2. **The omp backend invocation (#115 "to be defined").** What is the headless
   "ask omp a prompt and stream the answer" invocation, and which omp profile is
   the evaluator (a fast/cheap one, presumably, configurable)? This is the one
   piece I won't guess at — it touches omp integration you own. Until it's
   defined, the `Asker` ships against a stub so the box is buildable/reviewable.
3. **Input widget**: hand-rolled minimal input (zero new deps) for a first cut, or
   pull in `bubbles/textarea` (multi-line, nicer, another dep)? Ties into Q1.
4. **Act confirmation granularity**: whole proposed set accepted/rejected at once,
   or per-Action toggles in the diff before applying?

## Phased plan

- **P0 (this doc)** — agree the shape + the open questions above.
- **P1** — `clikit.PromptBox` + the interfaces + `clikit.Run`, Ask mode against a
  **stub** backend; `atyrode` mounts a toggleable Ask panel (#117) as the first,
  safest consumer. Validates box + contract end-to-end.
- **P2** — real omp `Asker` (once Q2 is answered); grounding from a generated
  capabilities doc for `atyrode` and the wiki/`models.yml` for `code`.
- **P3** — Act mode + `Commander` in `code` (#116): diff + confirm, reset = undo,
  then launch the omp session with the chosen profile and forward the prompt.

## Non-goals

- No speculative abstraction ahead of the second consumer — the interfaces ship
  *with* #115's real usage, validated by `code` + `atyrode` before codifying.
- Not a plugin system — capabilities are compile-time Go interfaces, not runtime
  discovery.
- No per-tool knowledge in `cli-kit` — the box knows nothing about `code` facets
  or `atyrode` commands.
