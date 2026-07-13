package clikit

import (
	"context"
	"errors"
	"strings"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// errNoChanges is shown when a Commander returns an empty proposal.
var errNoChanges = errors.New("no changes proposed")

// PromptBox is the shared "smart prompt box": type a prompt, watch the agent
// think, and read a streamed answer. It is a self-contained Bubble Tea component
// backed by an Asker (Ask mode). The heavy backend (omp) lives behind the Asker
// interface, so the box itself depends on nothing tool-specific.
//
// It is normally mounted by Run, which wires the host's Asker and a toggle key;
// it can also be embedded directly by a consumer that wants finer control.

type boxState int

const (
	boxEditing  boxState = iota // composing a prompt
	boxBusy                     // request in flight / streaming
	boxDone                     // answer complete (or errored)
	boxProposed                 // Act mode: showing proposed actions, awaiting confirm
)

// streamStarted carries the channel back from the (possibly slow) Ask call so the
// UI thread never blocks starting the backend.
type streamStarted struct {
	seq int
	ch  <-chan string
	err error
}

// promptToken is one streamed chunk; ok=false marks the stream closed. The
// channel rides along so the read Cmd is self-perpetuating without box state.
type promptToken struct {
	seq int
	ch  <-chan string
	tok string
	ok  bool
}

// BoxCloseMsg is emitted when the user dismisses an idle box (esc while editing).
// A host (see Run) listens for it to hide the box.
type BoxCloseMsg struct{}

// ActionsConfirmedMsg is emitted when the user accepts a Commander's proposal.
// The host (see Run, which forwards it to the app) applies the actions. Prompt is
// the text the user submitted, so a host can carry it forward (e.g. as the first
// message of the session it launches).
type ActionsConfirmedMsg struct {
	Actions []Action
	Prompt  string
}

// PromptBox is a value type — Update returns an updated copy, matching the
// bubbles convention.
type PromptBox struct {
	ta    textarea.Model
	vp    viewport.Model
	spin  spinner.Model
	asker Asker
	cmd   Commander

	w, h     int
	title    string // optional header (e.g. the evaluator model in use)
	state    boxState
	acting   bool // the current stream is an Act proposal (parse on close)
	answer   string
	prompt   string   // the submitted prompt (carried into ActionsConfirmedMsg)
	proposed []Action // Act mode: the actions awaiting confirmation
	err      error

	seq    int // identifies the current request; stale async msgs are dropped
	cancel context.CancelFunc
}

// NewPromptBox builds a box in the editing state. Call SetAsker to give it a
// backend and SetSize before rendering.
func NewPromptBox() PromptBox {
	ta := textarea.New()
	ta.Placeholder = "Ask…"
	ta.Prompt = "› "
	ta.ShowLineNumbers = false
	ta.CharLimit = 0
	ta.Focus()

	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = StDim

	return PromptBox{ta: ta, vp: viewport.New(0, 0), spin: sp, state: boxEditing}
}

// SetAsker wires the read-only backend. Without one, submitting is a no-op.
func (b *PromptBox) SetAsker(a Asker) { b.asker = a }

// SetCommander wires the Act-mode backend. When set, submitting asks the
// Commander for a proposal (streamed live, then shown for confirmation) instead
// of streaming a plain answer; it takes precedence over an Asker.
func (b *PromptBox) SetCommander(c Commander) { b.cmd = c }

// SetTitle sets an optional header line (e.g. "prompt → profile · gpt-5.6-luna")
// so the user can see what the box is doing / which model it uses.
func (b *PromptBox) SetTitle(s string) { b.title = s }

// SetSize lays the box out within w×h (outer cells). A border + one column of
// padding sit inside, so the inner widgets get w-4.
func (b *PromptBox) SetSize(w, h int) {
	b.w, b.h = w, h
	inner := w - 4
	if inner < 8 {
		inner = 8
	}
	b.ta.SetWidth(inner)
	b.ta.SetHeight(3)
	vpH := h - 8 // reserve rows for border, input, and the status line
	if vpH < 1 {
		vpH = 1
	}
	b.vp.Width, b.vp.Height = inner, vpH
	if b.answer != "" {
		b.vp.SetContent(b.wrapAnswer())
	}
}

// Init starts the spinner ticking.
func (b PromptBox) Init() tea.Cmd { return b.spin.Tick }

// Focused reports whether the box currently owns keyboard input.
func (b PromptBox) Busy() bool { return b.state == boxBusy }

func readToken(seq int, ch <-chan string) tea.Cmd {
	return func() tea.Msg {
		tok, ok := <-ch
		return promptToken{seq: seq, ch: ch, tok: tok, ok: ok}
	}
}

// submit fires the current prompt at the backend. It returns quickly: the
// backend call runs inside a Cmd so a slow start never blocks the UI. Act mode
// (a Commander) takes precedence over Ask (an Asker).
func (b *PromptBox) submit() tea.Cmd {
	prompt := strings.TrimSpace(b.ta.Value())
	if prompt == "" {
		return nil
	}
	b.state = boxBusy
	b.answer, b.err, b.proposed = "", nil, nil
	b.prompt = prompt
	b.seq++
	seq := b.seq
	ctx, cancel := context.WithCancel(context.Background())
	b.cancel = cancel
	b.vp.SetContent("")
	// The spinner keeps ticking on its own (see the TickMsg case); submit only
	// kicks off the backend, in a Cmd so a slow start never blocks the UI.
	switch {
	case b.cmd != nil: // Act mode — stream the proposal, parse on close
		b.acting = true
		cmder := b.cmd
		return func() tea.Msg {
			ch, err := cmder.Propose(ctx, prompt)
			return streamStarted{seq: seq, ch: ch, err: err}
		}
	case b.asker != nil: // Ask mode
		b.acting = false
		asker := b.asker
		return func() tea.Msg {
			ch, err := asker.Ask(ctx, prompt)
			return streamStarted{seq: seq, ch: ch, err: err}
		}
	default:
		b.state = boxEditing
		return nil
	}
}

// cancel stops any in-flight request and returns the box to editing. Bumping seq
// makes the stream's trailing (closing) token stale so it is ignored.
func (b *PromptBox) stop() {
	if b.cancel != nil {
		b.cancel()
		b.cancel = nil
	}
	b.seq++
	b.state = boxEditing
}

// Update advances the box. It returns a possibly-updated copy plus a Cmd. When
// the user dismisses an idle box, the Cmd emits BoxCloseMsg for the host.
func (b PromptBox) Update(msg tea.Msg) (PromptBox, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "enter":
			switch b.state {
			case boxBusy:
				return b, nil
			case boxProposed: // accept the proposal → hand it to the host
				actions, prompt := b.proposed, b.prompt
				b.proposed, b.state = nil, boxEditing
				return b, func() tea.Msg { return ActionsConfirmedMsg{Actions: actions, Prompt: prompt} }
			default: // enter submits; the box is a single prompt line
				return b, b.submit()
			}
		case "esc":
			switch b.state {
			case boxBusy:
				b.stop()
				return b, nil
			case boxProposed: // reject the proposal, back to editing
				b.proposed, b.state = nil, boxEditing
				return b, nil
			default:
				return b, func() tea.Msg { return BoxCloseMsg{} }
			}
		}
		if b.state == boxBusy || b.state == boxProposed { // ignore edits mid-flow
			return b, nil
		}
		var cmd tea.Cmd
		b.ta, cmd = b.ta.Update(msg)
		return b, cmd

	case spinner.TickMsg:
		// Always advance so the tick chain stays alive; it's only displayed while
		// busy (see View).
		var cmd tea.Cmd
		b.spin, cmd = b.spin.Update(msg)
		return b, cmd

	case streamStarted:
		if msg.seq != b.seq {
			return b, nil // stale
		}
		if msg.err != nil {
			b.state, b.err = boxDone, msg.err
			return b, nil
		}
		return b, readToken(msg.seq, msg.ch)

	case promptToken:
		if msg.seq != b.seq {
			return b, nil // stale (cancelled or superseded)
		}
		if !msg.ok { // stream closed
			if b.acting && b.cmd != nil { // Act: parse the streamed output
				actions, err := b.cmd.Parse(b.answer)
				switch {
				case err != nil:
					b.state, b.err = boxDone, err
				case len(actions) == 0:
					b.state, b.err = boxDone, errNoChanges
				default:
					b.proposed, b.state = actions, boxProposed
				}
			} else {
				b.state = boxDone
			}
			return b, nil
		}
		b.answer += msg.tok
		b.vp.SetContent(b.wrapAnswer())
		b.vp.GotoBottom()
		return b, readToken(msg.seq, msg.ch)
	}

	// Everything else (mouse, etc.) goes to whichever pane is live.
	var cmd tea.Cmd
	if b.state == boxEditing {
		b.ta, cmd = b.ta.Update(msg)
	} else {
		b.vp, cmd = b.vp.Update(msg)
	}
	return b, cmd
}

func (b PromptBox) wrapAnswer() string {
	w := b.vp.Width
	if w < 1 {
		w = 1
	}
	return lipgloss.NewStyle().Width(w).Render(b.answer)
}

// View renders the box: a prompt input, then either a "thinking" line, the
// streamed answer, or an error.
func (b PromptBox) View() string {
	var parts []string
	if b.title != "" {
		parts = append(parts, StHead.Render(b.title))
	}
	parts = append(parts, b.ta.View())

	switch b.state {
	case boxBusy:
		if b.answer == "" {
			parts = append(parts, StDim.Render(b.spin.View()+" thinking…"))
		} else {
			parts = append(parts, b.vp.View())
		}
	case boxDone:
		if b.err != nil {
			parts = append(parts, StBrk.Render(GBroken+" "+b.err.Error()))
		} else {
			parts = append(parts, b.vp.View())
		}
	case boxProposed:
		lines := []string{StHead.Render("proposed changes")}
		for _, a := range b.proposed {
			lines = append(lines, "  "+a.Key+" → "+StWarn.Render(a.Value))
		}
		lines = append(lines, StDim.Render("enter apply · esc cancel"))
		parts = append(parts, strings.Join(lines, "\n"))
	}

	body := lipgloss.JoinVertical(lipgloss.Left, parts...)
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color(CBord)).
		Padding(0, 1).
		Width(b.w - 2). // border adds the outer 2 cols back
		Render(body)
}
