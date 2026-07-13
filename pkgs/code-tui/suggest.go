package main

import (
	"fmt"
	"os"
	"strings"

	clikit "cli-kit"
)

// facetGuide is a one-line hint per facet, grounding the evaluator so it picks
// sensibly (the facet values themselves come from facetDefs).
var facetGuide = map[string]string{
	"lane":     "which model pools to draw from",
	"model":    "speed/quality tier — fast is cheap, smart is strongest",
	"thinking": "reasoning depth, minimal→max",
	"advisor":  "a peer-reviewer each turn: off, a quick glance, a review, or a deep (expensive) audit",
	"spark":    "use the fast idle-bucket coder for background/execution work",
	"fable":    "allow the scarce elite Fable lead",
	"fast":     "force the fast execution model",
}

// actDocs builds the Act-mode system prompt: the option schema (from the facets)
// plus a demand for a JSON-only reply of the options to change.
func actDocs(facets []facet) clikit.DocCorpus {
	var b strings.Builder
	b.WriteString("You configure a coding-agent session. You do NOT answer, research, " +
		"or perform the user's task — you only pick the best configuration options for " +
		"someone else to run it. Treat the user's message purely as a description of the " +
		"work to size.\n\nOptions:\n")
	for _, f := range facets {
		b.WriteString(fmt.Sprintf("- %s: one of [%s] — %s\n",
			f.key, strings.Join(f.values, ", "), facetGuide[f.key]))
	}
	b.WriteString("\nRespond with one short sentence on why, then a JSON object (on its " +
		"own line) mapping ONLY the options you want to CHANGE to their chosen values — " +
		"omit options left at default, and use exactly the option names and values listed " +
		"above. Do not answer the task itself. Example:\n" +
		"Quick but precise task, so a fast model with more thinking.\n" +
		"{\"model\":\"fast\",\"thinking\":\"high\"}")
	return clikit.DocCorpus(b.String())
}

// defaultEvalModel is a fast, cheap evaluator — Anthropic's cheapest tier, which
// is reliably authed and strong at instruction-following/JSON. With thinking off
// (below) it's quick. Override with CODE_EVAL_MODEL (e.g. gpt-5.6-luna if your
// Codex is authed); thinking is tunable via CODE_EVAL_THINKING.
const defaultEvalModel = "claude-haiku-4-5"

func evalModel() string {
	if v := os.Getenv("CODE_EVAL_MODEL"); v != "" {
		return v
	}
	return defaultEvalModel
}

// Commander implements clikit.Commandable: a cheap omp-backed evaluator that
// proposes facet changes for the user's task. It uses bare omp (CODE_OMP_EVAL)
// with an explicit lightweight model, not the managed launcher.
func (m model) Commander() clikit.Commander {
	c := clikit.NewOmpCommander(actDocs(m.facets))
	if bin := os.Getenv("CODE_OMP_EVAL"); bin != "" {
		c.Bin = bin
	}
	c.Model = evalModel()
	if v := os.Getenv("CODE_EVAL_THINKING"); v != "" {
		c.Thinking = v
	}
	return c
}

// BoxTitle labels the suggest box with its purpose and the model in use, so the
// user knows what they're invoking.
func (m model) BoxTitle() string { return "prompt → profile · " + evalModel() }

// validFacetActions keeps only the actions that name a real facet with a value
// that facet offers — the whitelist that makes an agent proposal no more powerful
// than a manual change.
func validFacetActions(facets []facet, actions []clikit.Action) []clikit.Action {
	valid := map[string]map[string]bool{}
	for _, f := range facets {
		vs := map[string]bool{}
		for _, v := range f.values {
			vs[v] = true
		}
		valid[f.key] = vs
	}
	var out []clikit.Action
	for _, a := range actions {
		if vs, ok := valid[a.Key]; ok && vs[a.Value] {
			out = append(out, a)
		}
	}
	return out
}

// applyActions applies a confirmed proposal: each valid facet=value updates the
// selection, exactly as a manual change would, then the preview refreshes.
func (m *model) applyActions(actions []clikit.Action) {
	for _, a := range validFacetActions(m.facets, actions) {
		m.sel[a.Key] = a.Value
	}
	m.syncPreview()
}
