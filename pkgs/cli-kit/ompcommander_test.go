package clikit

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestParseActions(t *testing.T) {
	// Clean JSON, sorted deterministically, booleans normalised to on/off.
	got, err := parseActions([]byte(`{"model":"fast","spark":true,"fable":false}`))
	if err != nil {
		t.Fatalf("parseActions: %v", err)
	}
	want := []Action{{"fable", "off"}, {"model", "fast"}, {"spark", "on"}}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("action %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestParseActionsEmbeddedInProse(t *testing.T) {
	out := []byte("Sure! Here's my suggestion:\n{\"thinking\": \"high\"}\nHope that helps.")
	got, err := parseActions(out)
	if err != nil {
		t.Fatalf("parseActions: %v", err)
	}
	if len(got) != 1 || got[0] != (Action{"thinking", "high"}) {
		t.Errorf("got %v, want [{thinking high}]", got)
	}
}

func TestParseActionsNoJSON(t *testing.T) {
	if _, err := parseActions([]byte("I cannot help with that.")); err == nil {
		t.Error("expected an error when there is no JSON object")
	}
}

func TestOmpCommanderProposeParse(t *testing.T) {
	o := OmpCommander{Bin: "x", Model: "m"}
	// Substitute a stand-in for omp that streams a fixed JSON object; Propose
	// builds its own args, which the helper ignores.
	orig := execCommandContext
	execCommandContext = func(ctx context.Context, _ string, _ ...string) *exec.Cmd {
		c := exec.CommandContext(ctx, os.Args[0], "-test.run=TestHelperProcess")
		c.Env = append(os.Environ(), "GO_HELPER=json")
		return c
	}
	defer func() { execCommandContext = orig }()

	ch, err := o.Propose(context.Background(), "quick but precise")
	if err != nil {
		t.Fatalf("Propose: %v", err)
	}
	var out strings.Builder
	for s := range ch {
		out.WriteString(s)
	}
	got, err := o.Parse(out.String())
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(got) != 2 || got[0] != (Action{"model", "fast"}) || got[1] != (Action{"thinking", "high"}) {
		t.Errorf("proposal = %v, want [{model fast} {thinking high}]", got)
	}
}
