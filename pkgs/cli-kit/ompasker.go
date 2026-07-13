package clikit

import (
	"context"
	"os/exec"
)

// DefaultEvaluatorModel is the model an OmpAsker uses unless overridden. Haiku is
// the cheapest input tier (input dominates, since the docs corpus is injected on
// every call) with strong structured-output instruction-following — see
// DESIGN-promptbox.md. Configure per host via OmpAsker.Model or PI_SMOL_MODEL.
const DefaultEvaluatorModel = "claude-haiku-4-5"

// OmpAsker is the real Ask backend: it shells out to a headless omp run and
// streams the answer. It depends on nothing but os/exec — the omp binary is
// invoked at runtime, never linked. Cancelling the Ask context kills the omp
// subprocess (exec.CommandContext), satisfying esc-to-cancel.
type OmpAsker struct {
	Bin   string    // omp binary; defaults to "omp" on PATH
	Model string    // evaluator model; defaults to DefaultEvaluatorModel
	Docs  DocCorpus // grounding, appended to omp's system prompt
}

// NewOmpAsker builds an OmpAsker grounded in docs, with the default binary and
// evaluator model.
func NewOmpAsker(docs DocCorpus) OmpAsker {
	return OmpAsker{Bin: "omp", Model: DefaultEvaluatorModel, Docs: docs}
}

// ompArgs assembles the headless, read-only invocation: process one prompt and
// exit (-p), plain streamed text, no session, no tools, grounded by the docs.
// Kept pure so the exact command line is unit-testable.
func ompArgs(model string, docs DocCorpus, prompt string) []string {
	args := []string{"-p", "--mode", "text", "--no-session", "--no-tools"}
	if model != "" {
		args = append(args, "--model", model)
	}
	if docs != "" {
		args = append(args, "--append-system-prompt", string(docs))
	}
	return append(args, prompt)
}

// Ask starts omp and streams its stdout as it arrives. The returned channel
// closes when omp exits or the context is cancelled (which kills omp).
func (o OmpAsker) Ask(ctx context.Context, prompt string) (<-chan string, error) {
	bin := o.Bin
	if bin == "" {
		bin = "omp"
	}
	model := o.Model
	if model == "" {
		model = DefaultEvaluatorModel
	}
	cmd := exec.CommandContext(ctx, bin, ompArgs(model, o.Docs, prompt)...)
	return streamCmd(ctx, cmd)
}

// streamCmd starts cmd and streams its stdout in chunks. It is separate from Ask
// so the streaming/cancellation machinery can be tested with any command.
func streamCmd(ctx context.Context, cmd *exec.Cmd) (<-chan string, error) {
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	ch := make(chan string)
	go func() {
		defer close(ch)
		buf := make([]byte, 512)
		for {
			n, rerr := stdout.Read(buf)
			if n > 0 {
				select {
				case ch <- string(buf[:n]):
				case <-ctx.Done():
					_ = cmd.Wait() // process already being killed by the context
					return
				}
			}
			if rerr != nil {
				break
			}
		}
		_ = cmd.Wait()
	}()
	return ch, nil
}
