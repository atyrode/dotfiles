package main

import (
	"context"
	"encoding/json"
	"strings"

	clikit "cli-kit"
)

// The ctrl+o suggest box maps a task description to generator facets with a
// LOCAL heuristic — no model call, no omp, no auth — so it's instant. The task
// really only implies three facets (how heavy/careful is the work): model,
// thinking, and advisor. lane/spark/fable are user preferences, left untouched.

// Signal words. Substring matches, so stems ("refactor", "migrat", "optimi")
// catch their variants. Tune freely — this is the whole "model".
var (
	heavyWords = []string{
		"refactor", "architect", "redesign", "migrat", "rewrite", "overhaul",
		"complex", "complicat", "difficult", "tricky", "deep", "debug",
		"investigat", "root cause", "optimi", "performance", "concurren",
		"race condition", "distributed", "security", "vulnerab", "across",
		"entire", "whole codebase", "framework", "algorithm", "scal",
	}
	lightWords = []string{
		"quick", "simple", "small", "tiny", "trivial", "typo", "rename",
		"format", "lint", "comment", "docs", "documentation", "readme",
		"question", "look up", "lookup", "check", "find ", "what is",
		"where", "how do", "list ", "show ", "print", "commit", "changelog", "bump",
	}
	preciseWords = []string{
		"precise", "exact", "correct", "thorough", "rigorous", "edge case",
		"careful", "accurate", "subtle",
	}
)

func countHits(text string, words []string) int {
	n := 0
	for _, w := range words {
		if strings.Contains(text, w) {
			n++
		}
	}
	return n
}

// classify picks model/thinking/advisor for a task, plus a one-line rationale.
func classify(task string) (rationale string, picks map[string]string) {
	t := strings.ToLower(task)
	heavy, light, precise := countHits(t, heavyWords), countHits(t, lightWords), countHits(t, preciseWords)

	model, thinking, advisor := "normal", "medium", "glance"
	switch {
	case heavy > light:
		model, thinking, advisor = "smart", "high", "review"
		rationale = "heavy/complex → strongest model, deep thinking, reviewer on"
	case light > heavy:
		model, thinking, advisor = "fast", "minimal", "off"
		rationale = "light/quick → fast model, minimal thinking, no advisor"
	default:
		rationale = "balanced → normal model, medium thinking"
	}
	if precise > 0 && (thinking == "minimal" || thinking == "low" || thinking == "medium") {
		thinking = "high"
		rationale += "; precise, so more thinking"
	}
	return rationale, map[string]string{"model": model, "thinking": thinking, "advisor": advisor}
}

// heuristicCommander implements clikit.Commander with the local classifier. It
// "streams" the rationale + a JSON object instantly, which the box parses like
// any proposal — so the whole box UX (live preview, keep/revert) is reused.
type heuristicCommander struct{}

func (heuristicCommander) Propose(ctx context.Context, prompt string) (<-chan string, error) {
	rationale, picks := classify(prompt)
	js, _ := json.Marshal(picks)
	ch := make(chan string, 1)
	ch <- rationale + "\n" + string(js)
	close(ch)
	return ch, nil
}

func (heuristicCommander) Parse(output string) ([]clikit.Action, error) {
	return clikit.ParseActions([]byte(output))
}

// Commander implements clikit.Commandable with the instant local classifier.
func (m model) Commander() clikit.Commander { return heuristicCommander{} }

// BoxTitle labels the suggest box.
func (m model) BoxTitle() string { return "prompt → profile" }

// validFacetActions keeps only actions that name a real facet with a value that
// facet offers — the whitelist that makes a proposal no more powerful than a
// manual change.
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

// applyActions applies a proposal: each valid facet=value updates the selection,
// exactly as a manual change would, then the preview refreshes.
func (m *model) applyActions(actions []clikit.Action) {
	for _, a := range validFacetActions(m.facets, actions) {
		m.sel[a.Key] = a.Value
	}
	m.syncPreview()
}
