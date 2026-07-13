package clikit

import (
	"context"
	"os"
	"os/exec"
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

func TestOmpCommanderActions(t *testing.T) {
	o := OmpCommander{Bin: os.Args[0]}
	// Point Bin at the helper, but Actions builds its own args; the helper ignores
	// them and prints a fixed JSON object.
	orig := execCommandContext
	execCommandContext = func(ctx context.Context, _ string, _ ...string) *exec.Cmd {
		c := exec.CommandContext(ctx, os.Args[0], "-test.run=TestHelperProcess")
		c.Env = append(os.Environ(), "GO_HELPER=json")
		return c
	}
	defer func() { execCommandContext = orig }()

	got, err := o.Actions(context.Background(), "quick but precise")
	if err != nil {
		t.Fatalf("Actions: %v", err)
	}
	if len(got) != 2 || got[0] != (Action{"model", "fast"}) || got[1] != (Action{"thinking", "high"}) {
		t.Errorf("Actions = %v, want [{model fast} {thinking high}]", got)
	}
}
