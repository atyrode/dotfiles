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

type resizeApp struct {
	width, height int
	resizes       []tea.WindowSizeMsg
}

func (resizeApp) Init() tea.Cmd { return nil }
func (a resizeApp) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if size, ok := msg.(tea.WindowSizeMsg); ok {
		a.width, a.height = size.Width, size.Height
		a.resizes = append(a.resizes, size)
	}
	return a, nil
}
func (resizeApp) View() string { return "" }

type resizeAskableApp struct{ resizeApp }

func (resizeAskableApp) Asker() Asker { return stubAsker{} }
func (a resizeAskableApp) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	next, cmd := a.resizeApp.Update(msg)
	a.resizeApp = next.(resizeApp)
	return a, cmd
}

func TestHostForwardsResizeToBareApp(t *testing.T) {
	h := newHost(resizeApp{})
	next, _ := h.Update(tea.WindowSizeMsg{Width: 72, Height: 26})
	got := next.(host).app.(resizeApp)
	if got.width != 72 || got.height != 26 {
		t.Fatalf("bare app size = %dx%d, want 72x26", got.width, got.height)
	}
}

func TestHostForwardsEffectiveResizeWithPromptBoxInactive(t *testing.T) {
	h := newHost(resizeAskableApp{})

	for _, size := range []tea.WindowSizeMsg{
		{Width: 72, Height: 26},
		{Width: 80, Height: 26}, // width only
		{Width: 80, Height: 26}, // unchanged
		{Width: 80, Height: 30}, // height only
		{Width: 80, Height: 30}, // unchanged
	} {
		next, _ := h.Update(size)
		h = next.(host)
	}

	got := h.app.(resizeAskableApp).resizes
	want := []tea.WindowSizeMsg{
		{Width: 72, Height: 26},
		{Width: 80, Height: 26},
		{Width: 80, Height: 30},
	}
	assertResizeHistory(t, got, want)
}

func TestHostForwardsEffectiveResizeWithPromptBoxActive(t *testing.T) {
	h := newHost(resizeAskableApp{})
	next, _ := h.Update(tea.WindowSizeMsg{Width: 72, Height: 26})
	h = next.(host)
	next, _ = h.Update(tea.KeyMsg{Type: tea.KeyCtrlO})
	h = next.(host)

	activeHeight := h.appH
	for _, size := range []tea.WindowSizeMsg{
		{Width: 80, Height: 26}, // width only
		{Width: 80, Height: 26}, // unchanged
		{Width: 80, Height: 30}, // height only
		{Width: 80, Height: 30}, // unchanged
	} {
		next, _ = h.Update(size)
		h = next.(host)
	}

	got := h.app.(resizeAskableApp).resizes
	want := []tea.WindowSizeMsg{
		{Width: 72, Height: 26},
		{Width: 72, Height: activeHeight},
		{Width: 80, Height: activeHeight},
		{Width: 80, Height: activeHeight + 4},
	}
	assertResizeHistory(t, got, want)
}

func assertResizeHistory(t *testing.T, got, want []tea.WindowSizeMsg) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("resize history length = %d (%v), want %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("resize[%d] = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// stubCommander streams optional output and parses to a fixed action set.
type stubCommander struct {
	actions []Action
	output  string
}

func (s stubCommander) Propose(ctx context.Context, prompt string) (<-chan string, error) {
	ch := make(chan string)
	go func() {
		defer close(ch)
		if s.output != "" {
			select {
			case ch <- s.output:
			case <-ctx.Done():
			}
		}
	}()
	return ch, nil
}

func (s stubCommander) Parse(output string) ([]Action, error) { return s.actions, nil }

type commandableApp struct{ tea.Model }

func (commandableApp) Commander() Commander { return stubCommander{} }

func TestHostMountsBoxForCommandable(t *testing.T) {
	if h := newHost(commandableApp{}); !h.hasBox {
		t.Error("Commandable app should get a prompt box")
	}
}

// driveToProposal runs submit's Cmd chain until the box emits ActionsProposedMsg,
// returning the box (now in boxProposed) and that message.
func driveToProposal(b PromptBox, cmd tea.Cmd) (PromptBox, ActionsProposedMsg, bool) {
	for cmd != nil {
		msg := cmd()
		if pm, ok := msg.(ActionsProposedMsg); ok {
			return b, pm, true
		}
		b, cmd = b.Update(msg)
	}
	return b, ActionsProposedMsg{}, false
}

func TestPromptBoxActProposeThenConfirm(t *testing.T) {
	want := []Action{{"model", "fast"}, {"thinking", "high"}}
	b := NewPromptBox()
	b.SetCommander(stubCommander{actions: want})
	b.SetSize(60, 20)
	b.ta.SetValue("quick but precise")

	// Submit → stream → the box proposes and emits the actions for live preview.
	b, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	b, proposed, ok := driveToProposal(b, cmd)
	if !ok {
		t.Fatal("expected an ActionsProposedMsg once the proposal parses")
	}
	if b.state != boxProposed {
		t.Fatalf("expected boxProposed, got %d", b.state)
	}
	if len(proposed.Actions) != 2 || proposed.Actions[0] != want[0] {
		t.Errorf("proposed actions = %v, want %v", proposed.Actions, want)
	}
	if !strings.Contains(b.View(), "fast") || !strings.Contains(b.View(), "keep") {
		t.Errorf("proposed view should list the actions + keep/revert, got:\n%s", b.View())
	}

	// Enter keeps → ActionsConfirmedMsg carrying the prompt, box back to editing.
	b, cmd = b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if b.state != boxEditing {
		t.Errorf("after keep, expected boxEditing, got %d", b.state)
	}
	msg, ok := cmd().(ActionsConfirmedMsg)
	if !ok {
		t.Fatalf("keep should emit ActionsConfirmedMsg, got %T", cmd())
	}
	if msg.Prompt != "quick but precise" {
		t.Errorf("confirmed prompt = %q, want the submitted text", msg.Prompt)
	}
}

func TestPromptBoxActEscReverts(t *testing.T) {
	b := NewPromptBox()
	b.SetCommander(stubCommander{actions: []Action{{"model", "fast"}}})
	b.SetSize(60, 20)
	b.ta.SetValue("x")

	b, cmd := b.Update(tea.KeyMsg{Type: tea.KeyEnter})
	b, _, ok := driveToProposal(b, cmd)
	if !ok || b.state != boxProposed {
		t.Fatalf("expected boxProposed, got state %d ok %v", b.state, ok)
	}
	b, cmd = b.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if b.state != boxEditing || b.proposed != nil {
		t.Errorf("esc should clear the proposal; state=%d proposed=%v", b.state, b.proposed)
	}
	if _, ok := cmd().(ActionsRevertedMsg); !ok {
		t.Errorf("esc should emit ActionsRevertedMsg, got %T", cmd())
	}
}
