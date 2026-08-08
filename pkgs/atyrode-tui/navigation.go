package main

import (
	"strings"

	clikit "github.com/atyrode/cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
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

func workspaceTabStyle(width int, active bool) lipgloss.Style {
	style := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color(clikit.CHead)).
		Align(lipgloss.Center).
		Width(width).
		MaxWidth(width)
	if active {
		style = style.
			Foreground(lipgloss.Color("#11151c")).
			Background(lipgloss.Color(clikit.CAcc))
	}
	return style
}

func (m model) workspaceTabs(width int) string {
	if width < 1 {
		return ""
	}
	items := m.nav.Items()
	columns := 2
	switch {
	case width >= 132:
		columns = 6
	case width >= 64:
		columns = 3
	}
	rows := make([]string, 0, (len(items)+columns-1)/columns)
	for start := 0; start < len(items); start += columns {
		end := min(start+columns, len(items))
		cells := make([]string, 0, end-start)
		for index := start; index < end; index++ {
			cellWidth := width / columns
			if index%columns < width%columns {
				cellWidth++
			}
			item := items[index]
			label := item.Shortcut + ". " + item.Label
			if item.ID == workspaceLifecycle && lipgloss.Width(label) > cellWidth {
				label = item.Shortcut + ". Gen / Clean"
			}
			if cellWidth > 1 {
				label = ansi.Truncate(label, cellWidth, "…")
			}
			style := workspaceTabStyle(cellWidth, item.ID == m.nav.Active())
			cells = append(cells, style.Render(label))
		}
		rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, cells...))
	}
	return strings.Join(rows, "\n")
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
	_, panelWidth := m.horizontalLayout()
	chromeRows += max(0, lipgloss.Height(m.workspaceTabs(panelWidth))-1)
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
