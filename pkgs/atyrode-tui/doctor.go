package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	inventorydata "atyrode-tui/inventory"
	clikit "github.com/atyrode/cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

type doctorTab int

const (
	doctorHostTab doctorTab = iota
	doctorSystemTab
	doctorToolsTab
)

type doctorHostReport struct {
	OK     bool   `json:"ok"`
	Host   string `json:"host"`
	Actual struct {
		System   string `json:"system"`
		Username string `json:"username"`
		Hostname string `json:"hostname"`
	} `json:"actual"`
	Registered json.RawMessage `json:"registered"`
}

type doctorCheck struct {
	ID          string          `json:"id"`
	Owner       string          `json:"owner"`
	Required    bool            `json:"required"`
	Status      string          `json:"status"`
	Code        *string         `json:"code"`
	Summary     string          `json:"summary"`
	Remediation *string         `json:"remediation"`
	Expected    json.RawMessage `json:"expected"`
	Actual      json.RawMessage `json:"actual"`
}

type doctorSystemReport struct {
	SchemaVersion    int           `json:"schemaVersion"`
	Command          string        `json:"command"`
	OK               bool          `json:"ok"`
	Host             string        `json:"host"`
	System           string        `json:"system"`
	Platform         string        `json:"platform"`
	Capabilities     []string      `json:"capabilities"`
	Checks           []doctorCheck `json:"checks"`
	MutationBoundary string        `json:"mutationBoundary"`
}

type doctorTool struct {
	Name         string   `json:"name"`
	Command      string   `json:"command"`
	Capability   string   `json:"capability"`
	Platform     *string  `json:"platform"`
	Status       string   `json:"status"`
	Path         string   `json:"path"`
	Expected     bool     `json:"expected"`
	Remediation  *string  `json:"remediation"`
	Version      string   `json:"version"`
	VersionOwner string   `json:"versionOwner"`
	MutableState string   `json:"mutableState"`
	LaunchModes  []string `json:"launchModes"`
}

type doctorReport struct {
	host        *doctorHostReport
	system      *doctorSystemReport
	tools       []doctorTool
	semanticErr error
	err         error
}

type doctorMsg struct {
	tab        doctorTab
	generation uint64
	report     doctorReport
}

func decodeDoctorJSON(out []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(out))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return err
	}
	return nil
}

func parseDoctorReport(tab doctorTab, out []byte) (doctorReport, error) {
	var report doctorReport
	switch tab {
	case doctorHostTab:
		value := new(doctorHostReport)
		if err := decodeDoctorJSON(out, value); err != nil {
			return report, fmt.Errorf("decode doctor host: %w", err)
		}
		if value.Host == "" || value.Actual.System == "" || value.Actual.Username == "" || value.Actual.Hostname == "" || len(value.Registered) == 0 || !json.Valid(value.Registered) {
			return report, fmt.Errorf("decode doctor host: incomplete report")
		}
		report.host = value
	case doctorSystemTab:
		value := new(doctorSystemReport)
		if err := decodeDoctorJSON(out, value); err != nil {
			return report, fmt.Errorf("decode doctor system: %w", err)
		}
		if value.SchemaVersion != 1 || value.Command != "doctor system" || value.Host == "" || value.System == "" || value.Platform == "" || value.MutationBoundary != "read-only probes" {
			return report, fmt.Errorf("decode doctor system: unsupported or incomplete report")
		}
		for _, check := range value.Checks {
			if check.ID == "" || check.Owner == "" || check.Summary == "" || (check.Status != "ok" && check.Status != "incomplete" && check.Status != "not-applicable") || !json.Valid(check.Expected) || !json.Valid(check.Actual) {
				return report, fmt.Errorf("decode doctor system: malformed check %q", check.ID)
			}
		}
		report.system = value
	case doctorToolsTab:
		if err := decodeDoctorJSON(out, &report.tools); err != nil {
			return report, fmt.Errorf("decode doctor tools: %w", err)
		}
		for _, tool := range report.tools {
			if tool.Name == "" || tool.Command == "" || tool.Capability == "" || (tool.Status != "ok" && tool.Status != "missing") || (tool.Status == "ok" && tool.Path == "") || (tool.Status == "missing" && tool.Remediation == nil) {
				return doctorReport{}, fmt.Errorf("decode doctor tools: malformed tool %q", tool.Name)
			}
		}
	}
	return report, nil
}

func doctorCommand(tab doctorTab) string {
	return [...]string{"host", "system", "tools"}[tab]
}

func (m *model) startDoctor(tab doctorTab) tea.Cmd {
	if m.doctorLoading[tab] {
		return nil
	}
	if m.doctorLoading[doctorHostTab] || m.doctorLoading[doctorSystemTab] || m.doctorLoading[doctorToolsTab] {
		m.cancelDoctor()
	}
	m.doctorGeneration++
	generation := m.doctorGeneration
	m.doctorRequested[tab], m.doctorLoading[tab], m.doctorErrors[tab] = true, true, nil
	ctx, cancel := context.WithCancel(context.Background())
	m.doctorCancel = cancel
	runner, cli := m.runner, m.cli
	return func() tea.Msg {
		out, err := runner.Output(ctx, cli, "doctor", doctorCommand(tab), "--json")
		report, decodeErr := parseDoctorReport(tab, out)
		if decodeErr != nil {
			report.err = decodeErr
		} else if err != nil {
			report.semanticErr = fmt.Errorf("doctor %s reported problems: %w", doctorCommand(tab), err)
		}
		return doctorMsg{tab: tab, generation: generation, report: report}
	}
}

func (m *model) cancelDoctor() {
	if m.doctorCancel != nil {
		m.doctorCancel()
		m.doctorCancel = nil
	}
	if m.doctorLoading[doctorHostTab] || m.doctorLoading[doctorSystemTab] || m.doctorLoading[doctorToolsTab] {
		m.doctorGeneration++
		for tab := range m.doctorLoading {
			if m.doctorLoading[tab] {
				m.doctorRequested[tab] = false
			}
		}
		m.doctorLoading = [3]bool{}
	}
}

func (m *model) doctorRefresh() tea.Cmd {
	m.cancelDoctor()
	m.doctorReports[m.doctorTab] = doctorReport{}
	m.doctorErrors[m.doctorTab] = nil
	m.doctorCursor = 0
	return m.startDoctor(m.doctorTab)
}

func (m model) doctorReportUnrequested(tab doctorTab) bool {
	return !m.doctorRequested[tab]
}

func (m *model) doctorUpdate(key string) tea.Cmd {
	switch key {
	case "r":
		return m.doctorRefresh()
	case "left", "[":
		m.doctorTab = doctorTab((int(m.doctorTab) + 2) % 3)
		m.doctorCursor = 0
	case "right", "]":
		m.doctorTab = doctorTab((int(m.doctorTab) + 1) % 3)
		m.doctorCursor = 0
	case "up", "k":
		m.doctorCursor = clampCursor(m.doctorCursor-1, len(m.doctorRows(m.contentPanelWidth()-4)))
	case "down", "j":
		m.doctorCursor = clampCursor(m.doctorCursor+1, len(m.doctorRows(m.contentPanelWidth()-4)))
	case "pgup":
		m.doctorCursor = clampCursor(m.doctorCursor-m.paneBodyHeight(), len(m.doctorRows(m.contentPanelWidth()-4)))
	case "pgdown":
		m.doctorCursor = clampCursor(m.doctorCursor+m.paneBodyHeight(), len(m.doctorRows(m.contentPanelWidth()-4)))
	}
	if m.doctorReportUnrequested(m.doctorTab) && !m.doctorLoading[m.doctorTab] {
		return m.startDoctor(m.doctorTab)
	}
	return nil
}

func (m *model) capabilitiesWorkspaceUpdate(key string) tea.Cmd {
	_, panelWidth := m.horizontalLayout()
	rowCount := len(m.capabilitiesWorkspaceRows(panelWidth))
	switch key {
	case "r":
		if m.plan.ResolvedRevision == "" {
			return nil
		}
		m.cancelInventory()
		m.inventory, m.inventoryErr = inventorydata.Document{}, nil
		m.inventoryRequested = false
		return m.startInventory()
	case "left", "[":
		*m = m.cycleCapability(-1)
	case "right", "]":
		*m = m.cycleCapability(1)
	case "up", "k":
		m.capabilityCursor = clampCursor(m.capabilityCursor-1, rowCount)
	case "down", "j":
		m.capabilityCursor = clampCursor(m.capabilityCursor+1, rowCount)
	case "pgup":
		m.capabilityCursor = clampCursor(m.capabilityCursor-m.paneBodyHeight(), rowCount)
	case "pgdown":
		m.capabilityCursor = clampCursor(m.capabilityCursor+m.paneBodyHeight(), rowCount)
	}
	return nil
}

func (m model) doctorView(width int) string {
	tabs := []string{"Host", "System", "Tools"}
	for i := range tabs {
		if doctorTab(i) == m.doctorTab {
			tabs[i] = clikit.StHead.Render("[" + tabs[i] + "]")
		}
	}
	bodyWidth := max(1, clikit.PanelContentWidth(width)-1)
	rows := m.doctorRows(max(1, bodyWidth-1))
	bodyHeight := min(max(1, len(rows)), m.workspaceBodyHeight())
	body := clikit.WindowList(rows, m.doctorCursor, bodyHeight, bodyWidth)
	return clikit.Panel(width, titleStyle.Render("Doctor")+"\n"+clikit.StDim.Render(strings.Join(tabs, "  "))+"\n\n"+body+"\n\n"+clikit.StDim.Render("←/→ tab · r refresh · ↑/↓ scroll"))
}

func (m model) doctorRows(width int) []string {
	if m.doctorLoading[m.doctorTab] {
		return []string{clikit.StDim.Render("Loading doctor " + doctorCommand(m.doctorTab) + " report…")}
	}
	if err := m.doctorErrors[m.doctorTab]; err != nil {
		return []string{titleStyle.Render("Report unavailable"), clikit.StDim.Render(err.Error())}
	}
	report := m.doctorReports[m.doctorTab]
	var rows []string
	if report.semanticErr != nil {
		rows = append(rows, clikit.StDim.Render(report.semanticErr.Error()))
	}
	switch m.doctorTab {
	case doctorHostTab:
		if report.host == nil {
			return []string{clikit.StDim.Render("Press r to load the host report.")}
		}
		status := "OK"
		if !report.host.OK {
			status = "MISMATCH"
		}
		rows = append(rows, titleStyle.Render(status), "Host: "+report.host.Host, "System: "+report.host.Actual.System, "User: "+report.host.Actual.Username, "Hostname: "+report.host.Actual.Hostname)
	case doctorSystemTab:
		if report.system == nil {
			return []string{clikit.StDim.Render("Press r to load the system report.")}
		}
		status := "OK"
		if !report.system.OK {
			status = "PROBLEMS FOUND"
		}
		rows = append(rows, titleStyle.Render(status), "Host: "+report.system.Host, "System: "+report.system.System)
		for _, check := range report.system.Checks {
			rows = append(rows, strings.ToUpper(check.Status)+" · "+check.ID+" · "+check.Summary)
		}
	case doctorToolsTab:
		if report.tools == nil {
			return []string{clikit.StDim.Render("Press r to load the tools report.")}
		}
		for _, tool := range report.tools {
			rows = append(rows, strings.ToUpper(tool.Status)+" · "+tool.Name+" · "+tool.Capability)
		}
	}
	for i, row := range rows {
		rows[i] = truncateDoctorRow(row, width)
	}
	return rows
}

func truncateDoctorRow(row string, width int) string {
	if width < 1 {
		return ""
	}
	return ansi.Truncate(row, width, "…")
}

func (m model) capabilitiesWorkspaceRows(width int) []string {
	bodyWidth := max(1, clikit.PanelContentWidth(width)-1)
	return m.capabilityRowsForWidth(max(1, bodyWidth-1))
}

func (m model) capabilitiesWorkspaceView(width int) string {
	if m.plan.ResolvedRevision == "" {
		return clikit.Panel(width, titleStyle.Render("Capabilities")+"\n\n"+clikit.StDim.Render("Open Apply to resolve the current host and exact revision."))
	}
	bodyWidth := max(1, clikit.PanelContentWidth(width)-1)
	rows := m.capabilitiesWorkspaceRows(width)
	bodyHeight := min(max(1, len(rows)), m.workspaceBodyHeight())
	body := clikit.WindowList(rows, m.capabilityCursor, bodyHeight, bodyWidth)
	return clikit.Panel(width, titleStyle.Render("Capabilities")+"\n\n"+body+"\n\n"+clikit.StDim.Render("r refresh · ←/→ capability · ↑/↓ scroll"))
}
