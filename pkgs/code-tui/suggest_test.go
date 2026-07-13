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

func TestActDocsSchema(t *testing.T) {
	docs := string(actDocs(facetDefs(map[string]string{})))
	// Every facet key and the JSON-only instruction must be present.
	for _, key := range []string{"lane", "model", "thinking", "advisor", "spark", "fable", "fast"} {
		if !strings.Contains(docs, key) {
			t.Errorf("actDocs missing facet %q", key)
		}
	}
	if !strings.Contains(docs, "JSON") {
		t.Errorf("actDocs must instruct a JSON reply")
	}
	// A representative value should be enumerated.
	if !strings.Contains(docs, "smart") {
		t.Errorf("actDocs should enumerate facet values (e.g. model=smart)")
	}
}
