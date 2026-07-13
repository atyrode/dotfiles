package clikit

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestOmpArgs(t *testing.T) {
	got := ompArgs("claude-haiku-4-5", "grounding docs", "why is the sky blue?")
	want := []string{
		"-p", "--mode", "text", "--no-session", "--no-tools",
		"--model", "claude-haiku-4-5",
		"--append-system-prompt", "grounding docs",
		"why is the sky blue?",
	}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("ompArgs = %v\nwant %v", got, want)
	}

	// No model and no docs: those flags are omitted, prompt still last.
	got = ompArgs("", "", "hi")
	want = []string{"-p", "--mode", "text", "--no-session", "--no-tools", "hi"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Errorf("ompArgs(no model/docs) = %v\nwant %v", got, want)
	}
}

func TestNewOmpAskerDefaults(t *testing.T) {
	o := NewOmpAsker("docs")
	if o.Bin != "omp" || o.Model != DefaultEvaluatorModel || o.Docs != "docs" {
		t.Errorf("NewOmpAsker defaults wrong: %+v", o)
	}
}

// TestStreamCmd runs this test binary in helper mode as a stand-in for omp, and
// asserts streamCmd relays its stdout.
func TestStreamCmd(t *testing.T) {
	ctx := context.Background()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=TestHelperProcess")
	cmd.Env = append(os.Environ(), "GO_HELPER=stream")
	ch, err := streamCmd(ctx, cmd)
	if err != nil {
		t.Fatalf("streamCmd: %v", err)
	}
	var got strings.Builder
	for s := range ch {
		got.WriteString(s)
	}
	if !strings.Contains(got.String(), "hello world") {
		t.Errorf("stream = %q, want to contain %q", got.String(), "hello world")
	}
}

// TestStreamCmdCancel proves cancelling the context stops a still-running command
// and closes the channel promptly (the helper would otherwise sleep 30s).
func TestStreamCmdCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=TestHelperProcess")
	cmd.Env = append(os.Environ(), "GO_HELPER=slow")
	ch, err := streamCmd(ctx, cmd)
	if err != nil {
		t.Fatalf("streamCmd: %v", err)
	}

	if _, ok := <-ch; !ok {
		t.Fatal("expected an initial chunk before cancel")
	}
	cancel()

	done := make(chan struct{})
	go func() {
		for range ch { // drain to completion
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("channel did not close within 5s of cancel — process not killed")
	}
}

// TestHelperProcess is not a real test: when GO_HELPER is set it impersonates omp
// (a subprocess), otherwise it returns immediately.
func TestHelperProcess(t *testing.T) {
	switch os.Getenv("GO_HELPER") {
	case "stream":
		fmt.Print("hello world")
		os.Exit(0)
	case "slow":
		fmt.Print("first chunk")
		time.Sleep(30 * time.Second) // killed by the context long before this
		os.Exit(0)
	}
}
