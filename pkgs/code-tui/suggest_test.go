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
	// Only the sizing facets are offered to the evaluator.
	for _, key := range []string{"lane", "model", "thinking", "advisor"} {
		if !strings.Contains(msg, key) {
			t.Errorf("classifyMessage missing sizing facet %q", key)
		}
	}
	// The budget/preference toggles must NOT be part of the suggestion.
	for _, key := range []string{"spark", "fable", "fast"} {
		if strings.Contains(msg, key+"[") {
			t.Errorf("classifyMessage should not offer non-sizing facet %q", key)
		}
	}
	// The two-line format (note + JSON) and an anchoring example must be present.
	if !strings.Contains(msg, "Line 1:") || !strings.Contains(msg, "Line 2:") {
		t.Errorf("classifyMessage must specify the two-line format, got:\n%s", msg)
	}
	// The user's prompt must be embedded as delimited data, not a bare instruction.
	if !strings.Contains(msg, "\"\"\"\ncheck the docs for X\n\"\"\"") {
		t.Errorf("classifyMessage must embed the prompt as delimited data, got:\n%s", msg)
	}
}

func TestTruncateForClassify(t *testing.T) {
	// A short prompt is passed through untouched.
	if got := truncateForClassify("small"); got != "small" {
		t.Errorf("short prompt altered: %q", got)
	}
	// A long paste is capped (bounding the CPU prompt-eval cost) and marked.
	long := strings.Repeat("x", maxClassifyChars+50)
	got := truncateForClassify(long)
	if len([]rune(got)) > maxClassifyChars+2 || !strings.HasSuffix(got, "…") {
		t.Errorf("long prompt not truncated+marked, len=%d", len([]rune(got)))
	}
}

func TestEvalSystemPromptIsSizerRole(t *testing.T) {
	s := string(evalSystemPrompt)
	if !strings.Contains(s, "never do") || !strings.Contains(s, "two lines") {
		t.Errorf("evalSystemPrompt should pin the sizer-only, two-line role, got: %q", s)
	}
}
