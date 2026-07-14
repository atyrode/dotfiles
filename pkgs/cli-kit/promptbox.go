package clikit

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// errNoProposal is shown when the backend didn't return a usable proposal —
// whether it errored, answered in prose, or proposed nothing. The raw output is
// displayed above it (see View), which carries the actual reason.
var errNoProposal = errors.New("no settings proposal in the output above")

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

// modelResidencyMsg reports the result of a load/unload toggle. loaded is the
// state that was aimed for; err is non-nil if the daemon call failed.
type modelResidencyMsg struct {
	loaded bool
	err    error
}

// toggleModel loads or unloads the local model in the background (a cold load can
// take many seconds), reporting the outcome as a modelResidencyMsg.
func toggleModel(l Loadable, load bool) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
		defer cancel()
		var err error
		if load {
			err = l.Load(ctx)
		} else {
			err = l.Unload(ctx)
		}
		return modelResidencyMsg{loaded: load, err: err}
	}
}

// ActionsProposedMsg is emitted as soon as a proposal is parsed. The host applies
// it immediately as a live preview (saving prior state), so the change is visible
// in the tool's own UI while the box shows keep/revert.
type ActionsProposedMsg struct{ Actions []Action }

// ActionsConfirmedMsg is emitted when the user KEEPS the applied proposal. Prompt
// is the text they submitted, so a host can carry it forward (e.g. as the first
// message of the session it launches). The actions were already applied via
// ActionsProposedMsg.
type ActionsConfirmedMsg struct{ Prompt string }

// ActionsRevertedMsg is emitted when the user rejects the applied proposal; the
// host restores the state it saved on ActionsProposedMsg.
type ActionsRevertedMsg struct{}

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

	startedAt time.Time     // when the current request was submitted
	took      time.Duration // wall time of the last completed request (0 until one finishes)

	loadable    Loadable  // set when the backend can load/unload a local model
	modelLoaded bool      // user-controlled residency intent (default unloaded)
	loading     bool      // a load/unload call is in flight
	loadStart   time.Time // when the in-flight load/unload began (for its elapsed)
	loadErr     error     // last load/unload failure, shown dimmed
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

// SetAsker wires the read-only backend. Without one, submitting is a no-op. A
// backend that is also Loadable enables the load/unload toggle.
func (b *PromptBox) SetAsker(a Asker) { b.asker = a; b.detectLoadable(a) }

// SetCommander wires the Act-mode backend. When set, submitting asks the
// Commander for a proposal (streamed live, then shown for confirmation) instead
// of streaming a plain answer; it takes precedence over an Asker. A Commander
// that is also Loadable enables the load/unload toggle.
func (b *PromptBox) SetCommander(c Commander) { b.cmd = c; b.detectLoadable(c) }

// detectLoadable records the backend as loadable if it implements Loadable, so
// the box shows the residency indicator and binds the toggle key.
func (b *PromptBox) detectLoadable(backend any) {
	if l, ok := backend.(Loadable); ok {
		b.loadable = l
	}
}

// SetTitle sets an optional header line (e.g. "prompt → profile · gpt-5.6-luna")
// so the user can see what the box is doing / which model it uses.
func (b *PromptBox) SetTitle(s string) { b.title = s }

// maxInputLines caps how tall the input grows as the user types; beyond it the
// textarea scrolls internally. The box starts one line tall (see syncInputHeight).
const maxInputLines = 6

// innerWidth is the usable content width inside the border + padding.
func (b PromptBox) innerWidth() int {
	inner := b.w - 4
	if inner < 8 {
		inner = 8
	}
	return inner
}

// SetSize lays the box out within w outer cells, with maxH the tallest the box
// may grow to (the host caps it so it never eats the whole screen). The box is
// content-sized: the input grows with what's typed and the answer pane fits its
// text, so an idle box is a single line rather than a half-screen panel.
func (b *PromptBox) SetSize(w, maxH int) {
	b.w, b.h = w, maxH
	b.ta.SetWidth(b.innerWidth())
	b.vp.Width = b.innerWidth()
	b.syncInputHeight()
	b.syncAnswerViewport()
}

// syncInputHeight grows the input to fit its content (1..maxInputLines), so the
// box expands line-by-line as the user writes and shrinks back when they clear it.
func (b *PromptBox) syncInputHeight() {
	lines := 1
	if v := b.ta.Value(); v != "" {
		lines = lipgloss.Height(lipgloss.NewStyle().Width(b.innerWidth()).Render(v))
	}
	if lines > maxInputLines {
		lines = maxInputLines
	}
	if lines < 1 {
		lines = 1
	}
	b.ta.SetHeight(lines)
}

// syncAnswerViewport sizes the answer pane to its content (up to what maxH
// leaves), so the box never reserves empty rows for an answer that isn't there.
func (b *PromptBox) syncAnswerViewport() {
	if b.answer == "" {
		b.vp.SetContent("")
		b.vp.Height = 0
		return
	}
	content := b.wrapAnswer()
	b.vp.SetContent(content)
	lines := lipgloss.Height(content)
	cap := b.h - b.ta.Height() - 5 // leave room for title, residency, border/pad
	if cap < 1 {
		cap = 1
	}
	if lines > cap {
		lines = cap
	}
	if lines < 1 {
		lines = 1
	}
	b.vp.Height = lines
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
	b.answer, b.err, b.proposed, b.took = "", nil, nil, 0
	b.prompt = prompt
	b.startedAt = time.Now()
	b.seq++
	seq := b.seq
	ctx, cancel := context.WithCancel(context.Background())
	b.cancel = cancel
	b.syncAnswerViewport()
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
		case "ctrl+l":
			// Toggle local-model residency. Ignored when there's no loadable
			// backend or a load/unload is already in flight.
			if b.loadable == nil || b.loading {
				return b, nil
			}
			b.loading, b.loadStart, b.loadErr = true, time.Now(), nil
			return b, toggleModel(b.loadable, !b.modelLoaded)
		case "enter":
			switch b.state {
			case boxBusy:
				return b, nil
			case boxProposed: // keep the (already-applied) proposal
				prompt := b.prompt
				b.proposed, b.state = nil, boxEditing
				return b, func() tea.Msg { return ActionsConfirmedMsg{Prompt: prompt} }
			default: // enter submits; the box is a single prompt line
				return b, b.submit()
			}
		case "esc":
			switch b.state {
			case boxBusy:
				b.stop()
				return b, nil
			case boxProposed: // reject → have the host revert the live preview
				b.proposed, b.state = nil, boxEditing
				return b, func() tea.Msg { return ActionsRevertedMsg{} }
			default:
				return b, func() tea.Msg { return BoxCloseMsg{} }
			}
		}
		if b.state == boxBusy || b.state == boxProposed { // ignore edits mid-flow
			return b, nil
		}
		var cmd tea.Cmd
		b.ta, cmd = b.ta.Update(msg)
		b.syncInputHeight() // grow/shrink the box with the typed text
		return b, cmd

	case modelResidencyMsg:
		b.loading = false
		b.loadErr = msg.err
		if msg.err == nil {
			b.modelLoaded = msg.loaded
		}
		return b, nil

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
			b.state, b.err, b.took = boxDone, msg.err, time.Since(b.startedAt)
			return b, nil
		}
		return b, readToken(msg.seq, msg.ch)

	case promptToken:
		if msg.seq != b.seq {
			return b, nil // stale (cancelled or superseded)
		}
		if !msg.ok { // stream closed
			b.took = time.Since(b.startedAt)
			if b.acting && b.cmd != nil { // Act: parse the streamed output
				actions, err := b.cmd.Parse(b.answer)
				switch {
				case err != nil || len(actions) == 0:
					// The output (shown above) wasn't a usable proposal — an omp
					// error, a prose answer, or nothing. Don't surface the JSON
					// parser's cryptic message; point at the output instead.
					b.state, b.err = boxDone, errNoProposal
				default:
					// Apply the proposal live (host previews it) and await keep/revert.
					b.proposed, b.state = actions, boxProposed
					return b, func() tea.Msg { return ActionsProposedMsg{Actions: actions} }
				}
			} else {
				b.state = boxDone
			}
			return b, nil
		}
		b.answer += msg.tok
		b.syncAnswerViewport()
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

// tookLine is a dimmed "took 1.8s" line for the done state (empty until a request
// has completed).
func (b PromptBox) tookLine() string {
	if b.took == 0 {
		return ""
	}
	return StDim.Render(fmt.Sprintf("took %.1fs", b.took.Seconds()))
}

// tookSuffix is the same figure as a " · 1.8s" suffix to append to a status line.
func (b PromptBox) tookSuffix() string {
	if b.took == 0 {
		return ""
	}
	return fmt.Sprintf(" · %.1fs", b.took.Seconds())
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
		// A live elapsed counter gives an honest feel for how long a local model
		// is taking (the first call after boot loads the model and is slow).
		elapsed := StDim.Render(fmt.Sprintf("%.1fs", time.Since(b.startedAt).Seconds()))
		if b.answer == "" {
			parts = append(parts, StDim.Render(b.spin.View()+" thinking… ")+elapsed)
		} else {
			parts = append(parts, b.vp.View(), StDim.Render(b.spin.View()+" ")+elapsed)
		}
	case boxDone:
		// Always keep the raw output visible — on an Act parse-failure it's the
		// diagnostic (what the model/omp actually said), not just the terse error.
		if b.answer != "" {
			parts = append(parts, b.vp.View())
		}
		if b.err != nil {
			parts = append(parts, StBrk.Render(GBroken+" "+b.err.Error()))
		}
		if t := b.tookLine(); t != "" {
			parts = append(parts, t)
		}
	case boxProposed:
		// Keep the model's reasoning + raw output visible alongside the proposal —
		// the short weight note is the "why" behind the picks, not just scaffolding.
		if b.answer != "" {
			parts = append(parts, b.vp.View())
		}
		lines := []string{StHead.Render("applied")}
		for _, a := range b.proposed {
			lines = append(lines, "  "+a.Key+" → "+StWarn.Render(a.Value))
		}
		lines = append(lines, StDim.Render("enter keep · esc revert"+b.tookSuffix()))
		parts = append(parts, strings.Join(lines, "\n"))
	}

	if line := b.residencyLine(); line != "" {
		parts = append(parts, line)
	}

	body := lipgloss.JoinVertical(lipgloss.Left, parts...)
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color(CBord)).
		Padding(0, 1).
		Width(b.w - 2). // border adds the outer 2 cols back
		Render(body)
}

// residencyLine is the model load/unload indicator, shown only when the backend
// is Loadable: a chip + on/off toggle plus the ^L hint, or a live progress line
// while a load/unload runs (a cold load is slow, so the elapsed matters).
func (b PromptBox) residencyLine() string {
	if b.loadable == nil {
		return ""
	}
	if b.loading {
		verb := "loading model"
		if b.modelLoaded {
			verb = "unloading model"
		}
		return StDim.Render(fmt.Sprintf("%s %s… %.1fs", b.spin.View(), verb, time.Since(b.loadStart).Seconds()))
	}
	var state string
	if b.modelLoaded {
		state = StOk.Render(GToggleOn + " loaded")
	} else {
		state = StDim.Render(GToggleOff + " unloaded")
	}
	line := StDim.Render(GMemory+" model ") + state + StDim.Render("  ^L")
	if b.loadErr != nil {
		line += "\n" + StBrk.Render(GBroken+" "+b.loadErr.Error())
	}
	return line
}
