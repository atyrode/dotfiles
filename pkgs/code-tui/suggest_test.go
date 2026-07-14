package main

import (
	"context"
	"testing"

	clikit "cli-kit"
)

func TestClassify(t *testing.T) {
	cases := []struct {
		task, model, thinking, advisor string
	}{
		// light / lookups → cheap and fast
		{"check gitingest documentation for api availability", "fast", "minimal", "off"},
		{"commit these staged changes", "fast", "minimal", "off"},
		{"fix a small typo in the readme", "fast", "minimal", "off"},
		// heavy / complex → strongest, deep, reviewer
		{"big careful refactor across many files", "smart", "high", "review"},
		{"investigate a race condition in the scheduler", "smart", "high", "review"},
		// light BUT precise → fast model, more thinking
		{"quick but precise bug fix", "fast", "high", "off"},
		// no strong signal → balanced defaults
		{"add a new endpoint to the app", "normal", "medium", "glance"},
	}
	for _, c := range cases {
		_, picks := classify(c.task)
		if picks["model"] != c.model || picks["thinking"] != c.thinking || picks["advisor"] != c.advisor {
			t.Errorf("classify(%q) = model=%s thinking=%s advisor=%s; want %s/%s/%s",
				c.task, picks["model"], picks["thinking"], picks["advisor"], c.model, c.thinking, c.advisor)
		}
	}
}

func TestHeuristicCommanderProposeParse(t *testing.T) {
	ch, err := heuristicCommander{}.Propose(context.Background(), "big careful refactor")
	if err != nil {
		t.Fatalf("Propose: %v", err)
	}
	var out string
	for s := range ch {
		out += s
	}
	got, err := heuristicCommander{}.Parse(out)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// Parsed, key-sorted: advisor, model, thinking.
	want := []clikit.Action{{"advisor", "review"}, {"model", "smart"}, {"thinking", "high"}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("action %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestValidFacetActions(t *testing.T) {
	facets := facetDefs(map[string]string{})
	in := []clikit.Action{
		{"model", "fast"},    // valid
		{"thinking", "high"}, // valid
		{"lane", "purple"},   // invalid value → dropped
		{"nonsense", "x"},    // unknown facet → dropped
		{"spark", "on"},      // valid
	}
	got := validFacetActions(facets, in)
	want := []clikit.Action{{"model", "fast"}, {"thinking", "high"}, {"spark", "on"}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("action %d = %v, want %v", i, got[i], want[i])
		}
	}
}
