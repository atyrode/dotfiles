package clikit

import "context"

// The cli-kit consumer contract. A CLI built on cli-kit is a Bubble Tea model
// (see Run); it opts into extra capabilities by implementing the small interfaces
// below. Go's structural typing makes this à-la-carte and compile-time — a tool
// implements only what it offers, and Run detects what's present and mounts the
// matching UI. Nothing here knows about any specific tool's internals.
//
// See DESIGN-promptbox.md for the full rationale (issues #115/#120/#121).

// Asker answers a prompt read-only, streaming the answer as string chunks on the
// returned channel and closing it when the answer is complete. Cancelling ctx
// MUST stop the underlying work (e.g. kill the omp subprocess) and close the
// channel; a non-nil error reports a failure to start.
type Asker interface {
	Ask(ctx context.Context, prompt string) (<-chan string, error)
}

// Action is one host-validated mutation the agent proposes in Act mode. Its
// meaning is the host's: for the code picker an Action is {facet, value}. The
// closed set a Commander returns IS the tool's agent-facing API surface.
type Action struct {
	Key   string
	Value string
}

// Commander proposes changes for a prompt in two parts so the box can show the
// model working: Propose streams the model's raw output (rationale + result) for
// live display, and Parse turns the completed output into a closed set of typed
// actions the host validates and applies. Cancelling ctx stops the work.
type Commander interface {
	Propose(ctx context.Context, prompt string) (<-chan string, error)
	Parse(output string) ([]Action, error)
}

// DocCorpus is grounding text a Documented host exposes; a real Asker backend
// injects it into the model's system prompt so answers are tool-specific.
type DocCorpus string

// The opt-in capabilities a host may implement. Each is independent.
type (
	// Askable enables the PromptBox in read-only Ask mode.
	Askable interface{ Asker() Asker }
	// Commandable additionally enables Act mode (propose → diff → confirm).
	Commandable interface{ Commander() Commander }
	// Documented supplies grounding for Ask/Act.
	Documented interface{ Docs() DocCorpus }
)
