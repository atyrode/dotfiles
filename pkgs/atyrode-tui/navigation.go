package main

import (
	"strings"

	clikit "cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const (
	workspaceOverview   clikit.WorkspaceID = "overview"
	workspaceApply      clikit.WorkspaceID = "apply"
	workspaceLifecycle  clikit.WorkspaceID = "lifecycle"
	workspaceDoctor     clikit.WorkspaceID = "doctor"
	workspaceCapability clikit.WorkspaceID = "capabilities"
	workspaceAsk        clikit.WorkspaceID = "ask"
)

var cockpitWorkspaceItems = []clikit.WorkspaceItem{
	{ID: workspaceOverview, Label: "Overview", Shortcut: "1"},
	{ID: workspaceApply, Label: "Apply", Shortcut: "2"},
	{ID: workspaceLifecycle, Label: "Generations / Clean", Shortcut: "3"},
	{ID: workspaceDoctor, Label: "Doctor", Shortcut: "4"},
	{ID: workspaceCapability, Label: "Capabilities", Shortcut: "5"},
	{ID: workspaceAsk, Label: "Ask", Shortcut: "6"},
}

func newCockpitNav() clikit.WorkspaceNav {
	return clikit.NewWorkspaceNav(cockpitWorkspaceItems...)
}

func workspaceForShortcut(key string) (clikit.WorkspaceID, bool) {
	for _, item := range cockpitWorkspaceItems {
		if item.Shortcut == key {
			return item.ID, true
		}
	}
	return "", false
}

func (m *model) activateWorkspace(id clikit.WorkspaceID) tea.Cmd {
	m.nav.Select(id)
	switch id {
	case workspaceApply:
		if m.applyRequested {
			return nil
		}
		m.applyRequested = true
		m.phase, m.err, m.status = loadingPlan, nil, ""
		return m.loadPlan()
	case workspaceLifecycle:
		if m.lifecycleLoading || len(m.generations) > 0 || m.lifecycleErr != nil {
			return nil
		}
		return m.loadLifecycle()
	case workspaceDoctor:
		if m.doctorReportUnrequested(m.doctorTab) && !m.doctorLoading[m.doctorTab] {
			return m.startDoctor(m.doctorTab)
		}
	case workspaceCapability:
		if m.plan.ResolvedRevision != "" {
			return m.startInventory()
		}
	default:
		return nil
	}
	return nil
}

func (m *model) nextWorkspace(delta int) tea.Cmd {
	var id clikit.WorkspaceID
	if delta < 0 {
		id = m.nav.Previous()
	} else {
		id = m.nav.Next()
	}
	return m.activateWorkspace(id)
}

func (m model) workspaceTitle() string {
	item, ok := m.nav.ActiveItem()
	if !ok {
		return "overview"
	}
	return strings.ToLower(item.Label)
}

func (m model) workspaceTabs(width int) string {
	items := m.nav.Items()
	parts := make([]string, 0, len(items))
	for _, item := range items {
		label := item.Shortcut + " " + item.Label
		if item.ID == m.nav.Active() {
			parts = append(parts, pillStyle.Render(label))
		} else {
			parts = append(parts, clikit.StDim.Render(label))
		}
	}
	return clikit.ClipLines(lipgloss.JoinHorizontal(lipgloss.Top, intersperse(parts, "  ")...), width)
}

func (m model) shellFooter() string {
	_, width := m.horizontalLayout()
	text := "Tab next workspace  ·  Shift+Tab previous  ·  1–6 jump  ·  Ctrl+O ask  ·  q quit"
	switch {
	case m.width < 60:
		text = "Tab/⇧Tab navigate  ·  1–6 jump  ·  q"
	case m.width < 112:
		text = "Tab/Shift+Tab navigate  ·  1–6 jump  ·  ^O ask  ·  q quit"
	}
	return clikit.ClipLines(clikit.StDim.Render(text), width)
}

// workspaceBodyHeight reserves the shared shell and panel chrome plus each
// workspace's local tabs and controls. Workspaces cap clipped lists with this
// value instead of preallocating unused terminal rows.
func (m model) workspaceBodyHeight() int {
	chromeRows := 12
	if m.nav.Active() == workspaceDoctor {
		chromeRows++
	}
	return max(1, m.height-chromeRows)
}

func intersperse(values []string, separator string) []string {
	if len(values) < 2 {
		return values
	}
	result := make([]string, 0, len(values)*2-1)
	for i, value := range values {
		if i > 0 {
			result = append(result, separator)
		}
		result = append(result, value)
	}
	return result
}
