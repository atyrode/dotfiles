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

## Resolved decisions

1. **`cli-kit` gains a Bubble Tea dependency — APPROVED (operator, 2026-07-13).**
   The `PromptBox` is a real Bubble Tea bubble (`Update(tea.Msg)`) and `clikit.Run`
   is the shared runner; `cli-kit` becomes Bubble-Tea-aware, not just lipgloss.
   This also settles the input widget: use **`bubbles/textarea`** (multi-line,
   proven) rather than hand-rolling.

2. **The omp backend invocation — RESOLVED (researched against omp v16.4.8 /
   `can1357/oh-my-pi`).** omp already exposes exactly what the box needs:

   - `-p, --print` — non-interactive: process one prompt and exit.
   - `--mode text|json|rpc|rpc-ui` — `text` streams answer tokens to stdout;
     `rpc` is "NDJSON commands in, response/event frames out" (structured
     streaming); `rpc-ui`/`acp` are the heavier permissioned tool-driving
     protocols (reserved for future real-tool Act, not needed for `code`).
   - `--append-system-prompt @<file>` — injects the grounding `DocCorpus`.
   - `--no-tools` (pure text answer, cheap/safe) · `--no-session` (ephemeral) ·
     `--model` / `--smol` (evaluator selection) · `--thinking` · `--max-time`.

   **Ask** (read-only, ship first):
   ```
   omp -p --mode text --no-session --no-tools \
       --model claude-haiku-4-5 \
       --append-system-prompt @<docs> "<question>"
   ```
   Stream stdout tokens into the viewport; cancel = kill the process. Upgrade
   path: `--mode rpc` (NDJSON frames) to separate thinking/answer/done, and/or a
   single long-lived rpc subprocess per box session to avoid per-question startup.

   **Act** (suggest facets): same one-shot, but the appended system prompt asks
   for a JSON object of `{facet: value}` proposals; the host parses it, renders a
   diff, and applies through the manual-selection path. No tools needed — the
   Action is structured text the host applies.

   Call **bare omp** (not the managed `omp-configured` wrapper) on the default
   profile's auth (auth-broker) — no `--profile` (that would force re-auth). The
   evaluator is a deliberate lightweight one-shot, outside the managed routing
   matrix.

   **Evaluator model = `claude-haiku-4-5` (default, configurable via `--model` /
   `PI_SMOL_MODEL`).** Cheapest input tier (cost_in $1/1M, tied with luna — and
   input dominates since the docs corpus is injected every call), fast (ttft 1.7s,
   48.9 tok/s), strong structured-output instruction-following, and consistent
   with the advisor's regular tier. Alternatives: **luna** (`gpt-5.6-luna`,
   marginally faster ttft, Codex bucket — pick if Claude-quota-constrained);
   **spark** (fastest generation + drains an idle bucket, but weak reasoning — only
   for trivial classification); **tiny local models** (`omp tiny-models`, zero API
   cost — a future path for pure classification, too weak for nuanced suggestion).

## Open questions for the operator

1. **Process model**: one `omp -p` per question (simple, ~1.7s startup+ttft each),
   or one long-lived `omp --mode rpc` subprocess per box session (warm, streams
   frames, more plumbing)? Recommend starting one-shot, upgrading to rpc if the
   per-question latency annoys.
2. **Act confirmation granularity**: whole proposed set accepted/rejected at once,
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
