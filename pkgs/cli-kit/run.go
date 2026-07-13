package clikit

import (
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

// WithToggleKey overrides the key that opens the prompt box (default "ctrl+o").
func WithToggleKey(k string) RunOption {
	return func(h *host) { h.toggleKey = k }
}

// WithAltScreen runs the program in the alternate screen buffer.
func WithAltScreen() RunOption {
	return func(h *host) { h.altScreen = true }
}

// Run starts app under a cli-kit host that auto-mounts capabilities. If app is
// Askable, a prompt box (Ask mode) is available via the toggle key; if it is also
// Documented, that grounding is available to the backend; Commandable is detected
// and reserved for Act mode. An app that implements none simply runs as-is.
func Run(app App, opts ...RunOption) error {
	h := newHost(app)
	for _, o := range opts {
		o(&h)
	}
	var teaOpts []tea.ProgramOption
	if h.altScreen {
		teaOpts = append(teaOpts, tea.WithAltScreen())
	}
	_, err := tea.NewProgram(h, teaOpts...).Run()
	return err
}

// host wraps a consumer App, overlaying the prompt box when active and routing
// input between the two.
type host struct {
	app       tea.Model
	box       PromptBox
	hasBox    bool
	active    bool
	toggleKey string
	altScreen bool
	w, h      int
}

func newHost(app App) host {
	h := host{app: app, toggleKey: "ctrl+o"}
	if a, ok := app.(Askable); ok {
		h.box = NewPromptBox()
		h.box.SetAsker(a.Asker())
		h.hasBox = true
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
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		h.w, h.h = msg.Width, msg.Height
		if h.hasBox {
			h.box.SetSize(msg.Width, msg.Height/2) // docks in the lower half
		}
		var cmd tea.Cmd
		h.app, cmd = h.app.Update(msg)
		return h, cmd

	case BoxCloseMsg:
		h.active = false
		return h, nil

	case tea.KeyMsg:
		if h.hasBox && !h.active && msg.String() == h.toggleKey {
			h.active = true
			return h, h.box.Focus()
		}
		if h.active {
			var cmd tea.Cmd
			h.box, cmd = h.box.Update(msg)
			return h, cmd
		}
		var cmd tea.Cmd
		h.app, cmd = h.app.Update(msg)
		return h, cmd
	}

	// Non-key messages (spinner ticks, stream tokens, mouse) go to whichever
	// component is live so the box can stream while open.
	if h.active {
		var cmd tea.Cmd
		h.box, cmd = h.box.Update(msg)
		return h, cmd
	}
	var cmd tea.Cmd
	h.app, cmd = h.app.Update(msg)
	return h, cmd
}

func (h host) View() string {
	if !h.active {
		return h.app.View()
	}
	boxV := h.box.View()
	appH := h.h - lipgloss.Height(boxV)
	if appH < 0 {
		appH = 0
	}
	appV := lipgloss.NewStyle().Height(appH).MaxHeight(appH).Render(h.app.View())
	return lipgloss.JoinVertical(lipgloss.Left, appV, boxV)
}

// Focus re-focuses the input; call when (re)opening the box.
func (b *PromptBox) Focus() tea.Cmd { return b.ta.Focus() }
