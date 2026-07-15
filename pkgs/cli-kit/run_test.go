package clikit

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

type filterTestApp struct{ id string }

func (a filterTestApp) Init() tea.Cmd                       { return nil }
func (a filterTestApp) Update(tea.Msg) (tea.Model, tea.Cmd) { return a, nil }
func (a filterTestApp) View() string                        { return a.id }

func TestWithMessageFilterReceivesCurrentConsumerApp(t *testing.T) {
	initial := newHost(filterTestApp{id: "initial"})
	current := newHost(filterTestApp{id: "current"})
	var seen tea.Model
	WithMessageFilter(func(m tea.Model, msg tea.Msg) tea.Msg {
		seen = m
		return nil
	})(&initial)

	if got := initial.filterMessage(current, tea.KeyMsg{}); got != nil {
		t.Fatalf("filter return = %#v, want nil", got)
	}
	app, ok := seen.(filterTestApp)
	if !ok || app.id != "current" {
		t.Fatalf("filter saw %#v, want the current consumer app", seen)
	}
}
