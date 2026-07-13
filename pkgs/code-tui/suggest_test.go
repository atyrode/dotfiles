package main

import (
	"strings"
	"testing"

	clikit "cli-kit"
)

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

func TestClassifyMessage(t *testing.T) {
	msg := classifyMessage(facetDefs(map[string]string{}), "check the docs for X")
	// The schema (every facet key + a representative value) must be present.
	for _, key := range []string{"lane", "model", "thinking", "advisor", "spark", "fable", "fast"} {
		if !strings.Contains(msg, key) {
			t.Errorf("classifyMessage missing facet %q", key)
		}
	}
	if !strings.Contains(msg, "smart") {
		t.Errorf("classifyMessage should enumerate facet values (e.g. model=smart)")
	}
	// The user's prompt must be embedded as delimited data, not left as a bare
	// instruction — that's the whole fix.
	if !strings.Contains(msg, "\"\"\"\ncheck the docs for X\n\"\"\"") {
		t.Errorf("classifyMessage must embed the prompt as delimited data, got:\n%s", msg)
	}
}

func TestEvalSystemPromptIsSelectorRole(t *testing.T) {
	s := string(evalSystemPrompt)
	if !strings.Contains(s, "never perform") || !strings.Contains(s, "settings") {
		t.Errorf("evalSystemPrompt should pin the selector-only role, got: %q", s)
	}
}
