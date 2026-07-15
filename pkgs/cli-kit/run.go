package clikit

import (
	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// App is the baseline a cli-kit TUI implements: a Bubble Tea model. It opts into
// extra capabilities (Askable/Commandable/Documented) by also implementing those
// interfaces; Run detects them and mounts the matching UI.
type App interface {
	tea.Model
}

// RunOption configures Run.
type RunOption func(*host)

// MessageFilter runs before Bubble Tea dispatches a message. Returning nil
// drops the message before Update and View, which is useful for coalescing
// high-rate input that would otherwise trigger redundant redraws. The model
// passed to the filter is the consumer app, not cli-kit's host wrapper.
type MessageFilter func(tea.Model, tea.Msg) tea.Msg

// WithToggleKey overrides the key that opens the prompt box (default "ctrl+o").
func WithToggleKey(k string) RunOption {
	return func(h *host) { h.toggleKey = k }
}

// WithAltScreen runs the program in the alternate screen buffer.
func WithAltScreen() RunOption {
	return func(h *host) { h.altScreen = true }
}

// WithMouseCellMotion enables cell-motion mouse reporting (e.g. wheel scroll).
func WithMouseCellMotion() RunOption {
	return func(h *host) { h.mouse = true }
}

// WithMessageFilter installs a pre-dispatch Bubble Tea message filter.
func WithMessageFilter(filter MessageFilter) RunOption {
	return func(h *host) { h.messageFilter = filter }
}

// Run starts app under a cli-kit host that auto-mounts capabilities: Askable gets
// a prompt box in Ask mode, Commandable in Act mode (precedence), Documented
// grounds the backend; an app implementing none simply runs as-is. It returns the
// app's final model (unwrapped from the host) so callers can read end state.
func Run(app App, opts ...RunOption) (tea.Model, error) {
	h := newHost(app)
	for _, o := range opts {
		o(&h)
	}
	var teaOpts []tea.ProgramOption
	if h.altScreen {
		teaOpts = append(teaOpts, tea.WithAltScreen())
	}
	if h.mouse {
		teaOpts = append(teaOpts, tea.WithMouseCellMotion())
	}
	if h.messageFilter != nil {
		teaOpts = append(teaOpts, tea.WithFilter(h.filterMessage))
	}
	final, err := tea.NewProgram(h, teaOpts...).Run()
	if fh, ok := final.(host); ok {
		return fh.app, err
	}
	return nil, err
}

// host wraps a consumer App, overlaying the prompt box when active and routing
// input between the two.
type host struct {
	app           tea.Model
	box           PromptBox
	hasBox        bool
	active        bool
	toggleKey     string
	altScreen     bool
	mouse         bool
	messageFilter MessageFilter
	w, h          int
	appW          int // width last handed to a capability app (see reflow); -1 until set
	appH          int // height last handed to a capability app (see reflow); -1 until set
}

// filterMessage unwraps the current host so consumer filters can reason about
// their own model while still running at Bubble Tea's pre-Update boundary.
func (h host) filterMessage(current tea.Model, msg tea.Msg) tea.Msg {
	if h.messageFilter == nil {
		return msg
	}
	if currentHost, ok := current.(host); ok {
		current = currentHost.app
	}
	return h.messageFilter(current, msg)
}

func newHost(app App) host {
	h := host{app: app, toggleKey: "ctrl+o", appW: -1, appH: -1}
	askable, isAsk := app.(Askable)
	commandable, isCmd := app.(Commandable)
	if isAsk || isCmd {
		h.box = NewPromptBox()
		h.hasBox = true
		if isAsk {
			h.box.SetAsker(askable.Asker())
		}
		if isCmd { // Act mode takes precedence when both are present
			h.box.SetCommander(commandable.Commander())
		}
		// Optional: let the app title the box (e.g. show the evaluator model).
		if t, ok := app.(interface{ BoxTitle() string }); ok {
			h.box.SetTitle(t.BoxTitle())
		}
	}
	return h
}

func (h host) Init() tea.Cmd {
	cmds := []tea.Cmd{h.app.Init()}
	if h.hasBox {
		cmds = append(cmds, h.box.Init())
	}
	return tea.Batch(cmds...)
}

func (h host) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		h.w, h.h = msg.Width, msg.Height
		if h.hasBox {
			h.box.SetSize(msg.Width, msg.Height/2) // the box may grow up to half
		}
		if !h.hasBox {
			h.app, cmd = h.app.Update(msg)
		}
		// The app is (re)sized by reflow below to the height the box leaves it.

	case BoxCloseMsg:
		h.active = false

	case ActionsProposedMsg:
		// Live preview: let the app apply it immediately (it owns the state the
		// actions mutate); the box stays open showing keep/revert.
		h.app, cmd = h.app.Update(msg)

	case AppliedActionsMsg:
		// The app reporting the authoritative applied set — hand it to the box.
		h.box, cmd = h.box.Update(msg)

	case ActionsConfirmedMsg, ActionsRevertedMsg:
		// Keep or revert the previewed proposal; either way the box closes and the
		// app handles it (commit, or restore the saved state).
		h.active = false
		h.app, cmd = h.app.Update(msg)

	case tea.KeyMsg:
		switch {
		case h.hasBox && !h.active && msg.String() == h.toggleKey:
			h.active = true
			cmd = h.box.Focus()
		case h.active && (msg.String() == h.toggleKey || msg.String() == "esc"):
			// Dismissing the overlay is one action even while a request is
			// streaming. Feeding esc through PromptBox first cancels its context
			// and invalidates trailing stream messages; then hide it immediately.
			h.box, cmd = h.box.Update(tea.KeyMsg{Type: tea.KeyEsc})
			h.active = false
		case h.active:
			h.box, cmd = h.box.Update(msg)
		default:
			h.app, cmd = h.app.Update(msg)
		}

	case spinner.TickMsg:
		// Deliver to BOTH: the app and the box each run their own spinner, and each
		// ignores ticks that aren't its own (spinner ticks carry an id). Routing to
		// only the active one would let the inactive spinner's tick chain die — that
		// is what froze the box's elapsed timer after it had been closed once.
		var ca, cb tea.Cmd
		h.app, ca = h.app.Update(msg)
		if h.hasBox {
			h.box, cb = h.box.Update(msg)
		}
		cmd = tea.Batch(ca, cb)

	default:
		// Other non-key messages (stream tokens, mouse) go to whichever component
		// is live so the box can stream while open.
		if h.active {
			h.box, cmd = h.box.Update(msg)
		} else {
			h.app, cmd = h.app.Update(msg)
		}
	}

	// Reflow: give the app exactly the height the box does not occupy, so opening
	// the box (or growing it as the user types) pushes the app's content up rather
	// than clipping its bottom (which was hiding the usage panel).
	return h, tea.Batch(cmd, h.reflow())
}

// reflow resizes the app to the space left over above the box, sending it a
// WindowSizeMsg whenever either effective dimension changes. When the box is
// closed the app gets the full height back.
func (h *host) reflow() tea.Cmd {
	if !h.hasBox || h.h == 0 {
		return nil
	}
	target := h.h
	if h.active {
		if target -= lipgloss.Height(h.box.View()); target < 0 {
			target = 0
		}
	}
	if h.w == h.appW && target == h.appH {
		return nil
	}
	h.appW, h.appH = h.w, target
	var cmd tea.Cmd
	h.app, cmd = h.app.Update(tea.WindowSizeMsg{Width: h.w, Height: target})
	return cmd
}

func (h host) View() string {
	if !h.active {
		return h.app.View()
	}
	// The app was already resized (reflow) to the space above the box, so just
	// stack them — no clipping.
	return lipgloss.JoinVertical(lipgloss.Left, h.app.View(), h.box.View())
}

// Focus re-focuses the input; call when (re)opening the box.
func (b *PromptBox) Focus() tea.Cmd { return b.ta.Focus() }
