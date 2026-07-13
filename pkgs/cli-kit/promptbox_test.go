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
