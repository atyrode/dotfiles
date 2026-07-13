package clikit

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
)

// OmpCommander is the Act backend: it runs a headless omp turn whose system
// prompt (Docs) REPLACES omp's default agent prompt and instructs the model to
// reply with a JSON object of the changes to make. Propose streams that output so
// the box shows the model working; Parse turns it into a sorted, deterministic
// Action set. Thinking defaults off — this is a fast classification, not deep
// reasoning. Depends only on os/exec and cancels via the context.
type OmpCommander struct {
	Bin      string    // omp binary; defaults to "omp"
	Model    string    // evaluator model; defaults to DefaultEvaluatorModel
	Thinking string    // reasoning level; defaults to "off" for speed
	Docs     DocCorpus // system prompt: describes the options, demands a JSON reply
}

// NewOmpCommander builds an OmpCommander with the default binary, evaluator, and
// thinking off. Docs must instruct the model to answer with a JSON object.
func NewOmpCommander(docs DocCorpus) OmpCommander {
	return OmpCommander{Bin: "omp", Model: DefaultEvaluatorModel, Thinking: "off", Docs: docs}
}

// execCommandContext is indirected so tests can substitute a stand-in for omp.
var execCommandContext = exec.CommandContext

// Propose runs omp and streams its output for live display.
func (o OmpCommander) Propose(ctx context.Context, prompt string) (<-chan string, error) {
	bin := o.Bin
	if bin == "" {
		bin = "omp"
	}
	model := o.Model
	if model == "" {
		model = DefaultEvaluatorModel
	}
	cmd := execCommandContext(ctx, bin, ompArgs(model, o.Thinking, true, o.Docs, prompt)...)
	return streamCmd(ctx, cmd)
}

// Parse turns the model's completed output into proposed changes.
func (o OmpCommander) Parse(output string) ([]Action, error) {
	return parseActions([]byte(output))
}

// parseActions extracts the JSON object from a model's output (tolerating any
// surrounding prose) and turns it into a key-sorted Action set — sorted so the
// proposal is deterministic regardless of JSON/map ordering.
func parseActions(out []byte) ([]Action, error) {
	obj := extractJSONObject(out)
	if obj == "" {
		return nil, fmt.Errorf("no JSON object in model output")
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(obj), &m); err != nil {
		return nil, fmt.Errorf("parsing proposal: %w", err)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	actions := make([]Action, 0, len(keys))
	for _, k := range keys {
		actions = append(actions, Action{Key: k, Value: valueToString(m[k])})
	}
	return actions, nil
}

// extractJSONObject returns the substring from the first '{' to the last '}',
// letting the model wrap its JSON in prose without breaking the parse.
func extractJSONObject(b []byte) string {
	i := bytes.IndexByte(b, '{')
	j := bytes.LastIndexByte(b, '}')
	if i < 0 || j < i {
		return ""
	}
	return string(b[i : j+1])
}

// valueToString normalises a JSON value to a facet-style string (booleans become
// on/off, matching how the toggles are spelled).
func valueToString(v any) string {
	switch x := v.(type) {
	case bool:
		if x {
			return "on"
		}
		return "off"
	case string:
		return x
	default:
		return fmt.Sprintf("%v", x)
	}
}
