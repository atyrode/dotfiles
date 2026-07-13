package clikit

import (
	"context"
	"os"
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

// ompArgs assembles the headless invocation: process one prompt and exit (-p),
// plain streamed text, no session, no tools. thinking (if set) pins the reasoning
// level. When replaceSystem is true this is BARE-CLASSIFIER mode: the docs REPLACE
// omp's default system prompt (--system-prompt) AND omp's agent scaffolding
// (rules, skills, extensions loaded from the managed ~/.omp) is stripped —
// otherwise omp behaves like a coding agent and answers the prompt instead of
// classifying it. When false the docs are appended and the agent stays intact.
// Kept pure so the command line is unit-testable.
func ompArgs(model, thinking string, replaceSystem bool, docs DocCorpus, prompt string) []string {
	args := []string{"-p", "--mode", "text", "--no-session", "--no-tools"}
	if replaceSystem {
		args = append(args, "--no-rules", "--no-skills", "--no-extensions")
	}
	if model != "" {
		args = append(args, "--model", model)
	}
	if thinking != "" {
		args = append(args, "--thinking", thinking)
	}
	if docs != "" {
		flag := "--append-system-prompt"
		if replaceSystem {
			flag = "--system-prompt"
		}
		args = append(args, flag, string(docs))
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
	cmd := exec.CommandContext(ctx, bin, ompArgs(model, "", false, o.Docs, prompt)...)
	return streamCmd(ctx, cmd)
}

// streamCmd starts cmd and streams its combined stdout+stderr in chunks. Merging
// stderr matters: omp reports failures (bad model, auth, rejected flags) there,
// so without it a failed run streams nothing and the box can't show what went
// wrong. It is separate from Ask so the streaming/cancellation machinery can be
// tested with any command.
func streamCmd(ctx context.Context, cmd *exec.Cmd) (<-chan string, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	cmd.Stdout = w
	cmd.Stderr = w
	if err := cmd.Start(); err != nil {
		w.Close()
		r.Close()
		return nil, err
	}
	w.Close() // the child holds its own dup of the write end
	ch := make(chan string)
	go func() {
		defer close(ch)
		defer r.Close()
		defer func() { _ = cmd.Wait() }()
		buf := make([]byte, 512)
		for {
			n, rerr := r.Read(buf)
			if n > 0 {
				select {
				case ch <- string(buf[:n]):
				case <-ctx.Done(): // process already being killed by the context
					return
				}
			}
			if rerr != nil {
				return
			}
		}
	}()
	return ch, nil
}
