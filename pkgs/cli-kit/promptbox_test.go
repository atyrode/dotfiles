package clikit

import (
	"context"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// stubAsker streams a fixed set of chunks, honouring cancellation.
type stubAsker struct{ chunks []string }

func (s stubAsker) Ask(ctx context.Context, prompt string) (<-chan string, error) {
	ch := make(chan string)
	go func() {
		defer close(ch)
		for _, c := range s.chunks {
			select {
			case <-ctx.Done():
				return
			case ch <- c:
			}
		}
	}()
	return ch, nil
}

// follow runs a Cmd chain synchronously to completion. submit and the stream
// steps each return a single Cmd whose msg feeds the next Update, so a plain loop
// settles the box (readToken's cmd() blocks on the channel, which the stub feeds).
func follow(b PromptBox, cmd tea.Cmd) PromptBox {
	for cmd != nil {
		b, cmd = b.Update(cmd())
	}
	return b
}

func TestPromptBoxStreamsAnswer(t *testing.T) {
	b := NewPromptBox()
	b.SetAsker(stubAsker{chunks: []string{"hello", " ", "world"}})
	b.SetSize(60, 20)
	b.ta.SetValue("what is up?")

	// Submit, then follow the stream to completion.
	b, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	b = follow(b, cmd)

	if b.state != boxDone {
		t.Fatalf("expected boxDone after stream closes, got state %d", b.state)
	}
	if b.answer != "hello world" {
		t.Errorf("answer = %q, want %q", b.answer, "hello world")
	}
	if !strings.Contains(b.View(), "hello world") {
		t.Errorf("View should show the streamed answer, got:\n%s", b.View())
	}
}

func TestPromptBoxEmptyPromptNoop(t *testing.T) {
	b := NewPromptBox()
	b.SetAsker(stubAsker{chunks: []string{"x"}})
	b.SetSize(60, 20)
	b.ta.SetValue("   ") // whitespace only

	b, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if b.state != boxEditing {
		t.Errorf("blank prompt should not start a request; state = %d", b.state)
	}
	if cmd != nil {
		t.Errorf("blank prompt should return no Cmd")
	}
}

func TestPromptBoxEscClosesWhenIdle(t *testing.T) {
	b := NewPromptBox()
	b.SetSize(60, 20)
	_, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("esc while editing should emit a Cmd")
	}
	if _, ok := cmd().(BoxCloseMsg); !ok {
		t.Errorf("esc while editing should emit BoxCloseMsg")
	}
}

func TestPromptBoxEscCancelsStream(t *testing.T) {
	b := NewPromptBox()
	b.SetAsker(stubAsker{chunks: []string{"a", "b", "c"}})
	b.SetSize(60, 20)
	b.ta.SetValue("go")

	b, _ = b.Update(tea.KeyMsg{Type: tea.KeyEnter}) // now busy
	if b.state != boxBusy {
		t.Fatalf("expected boxBusy after submit, got %d", b.state)
	}
	prevSeq := b.seq
	b, _ = b.Update(tea.KeyMsg{Type: tea.KeyEsc}) // cancel
	if b.state != boxEditing {
		t.Errorf("esc mid-stream should return to editing, got %d", b.state)
	}
	if b.seq == prevSeq {
		t.Errorf("cancel should bump seq so trailing tokens are dropped")
	}
}

// Capability detection: the host mounts a box only for an Askable app.
type askableApp struct{ tea.Model }

func (askableApp) Asker() Asker { return stubAsker{} }

type bareApp struct{ tea.Model }

func TestHostMountsBoxForAskable(t *testing.T) {
	if h := newHost(askableApp{}); !h.hasBox {
		t.Error("Askable app should get a prompt box")
	}
	if h := newHost(bareApp{}); h.hasBox {
		t.Error("bare app should not get a prompt box")
	}
}

// stubCommander proposes a fixed action set.
type stubCommander struct{ actions []Action }

func (s stubCommander) Actions(ctx context.Context, prompt string) ([]Action, error) {
	return s.actions, nil
}

type commandableApp struct{ tea.Model }

func (commandableApp) Commander() Commander { return stubCommander{} }

func TestHostMountsBoxForCommandable(t *testing.T) {
	if h := newHost(commandableApp{}); !h.hasBox {
		t.Error("Commandable app should get a prompt box")
	}
}

func TestPromptBoxActProposeThenConfirm(t *testing.T) {
	want := []Action{{"model", "fast"}, {"thinking", "high"}}
	b := NewPromptBox()
	b.SetCommander(stubCommander{actions: want})
	b.SetSize(60, 20)
	b.ta.SetValue("quick but precise")

	// Submit → the Commander proposes → box enters the proposed state.
	b, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	b = follow(b, cmd)
	if b.state != boxProposed {
		t.Fatalf("expected boxProposed after Commander returns, got %d", b.state)
	}
	if !strings.Contains(b.View(), "proposed changes") || !strings.Contains(b.View(), "fast") {
		t.Errorf("proposed view should list the actions, got:\n%s", b.View())
	}

	// Enter accepts → emits ActionsConfirmedMsg with the proposal, box back to editing.
	b, cmd = b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if b.state != boxEditing {
		t.Errorf("after accept, expected boxEditing, got %d", b.state)
	}
	if cmd == nil {
		t.Fatal("accept should emit a Cmd")
	}
	msg, ok := cmd().(ActionsConfirmedMsg)
	if !ok {
		t.Fatalf("accept should emit ActionsConfirmedMsg, got %T", cmd())
	}
	if len(msg.Actions) != 2 || msg.Actions[0] != want[0] {
		t.Errorf("confirmed actions = %v, want %v", msg.Actions, want)
	}
	if msg.Prompt != "quick but precise" {
		t.Errorf("confirmed prompt = %q, want the submitted text", msg.Prompt)
	}
}

func TestPromptBoxActEscRejects(t *testing.T) {
	b := NewPromptBox()
	b.SetCommander(stubCommander{actions: []Action{{"model", "fast"}}})
	b.SetSize(60, 20)
	b.ta.SetValue("x")

	b, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	b = follow(b, cmd)
	if b.state != boxProposed {
		t.Fatalf("expected boxProposed, got %d", b.state)
	}
	b, _ = b.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if b.state != boxEditing || b.proposed != nil {
		t.Errorf("esc should reject the proposal and clear it; state=%d proposed=%v", b.state, b.proposed)
	}
}
