package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	clikit "github.com/atyrode/cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// The Tunnel workspace is a view onto `atyrode tunnel`, never a second
// implementation of it. Reads go through `tunnel list --json`; grants and
// revocations run the CLI in the foreground because the Bitwarden unlock the CLI
// performs needs the real terminal, and because the vault gate must hold no
// matter which surface asked.
type tunnelMachine struct {
	Name             string `json:"name"`
	Role             string `json:"role"`
	Primary          bool   `json:"primary"`
	Keytype          string `json:"keytype"`
	Fingerprint      string `json:"fingerprint"`
	State            string `json:"state"`
	Granted          bool   `json:"granted"`
	ExpiresAt        *int64 `json:"expiresAt"`
	RemainingSeconds *int64 `json:"remainingSeconds"`
}

type tunnelReport struct {
	SchemaVersion  int             `json:"schemaVersion"`
	Now            int64           `json:"now"`
	RegistryPath   string          `json:"registryPath"`
	StatePath      string          `json:"statePath"`
	AuthorizedKeys string          `json:"authorizedKeys"`
	Machines       []tunnelMachine `json:"machines"`
}

type tunnelReportMsg struct {
	report tunnelReport
	err    error
}

type tunnelActionMsg struct {
	action  string
	machine string
	err     error
}

// The durations the CLI accepts, in the order the picker offers them. Keeping
// the flag values here means the cockpit can never offer a duration
// `atyrode tunnel grant --for` would reject; Short keeps every option visible
// in a pane too narrow for the prose labels.
var tunnelDurations = []struct {
	Flag  string
	Label string
	Short string
}{
	{Flag: "1h", Label: "1 hour", Short: "1h"},
	{Flag: "8h", Label: "8 hours", Short: "8h"},
	{Flag: "24h", Label: "24 hours", Short: "24h"},
	{Flag: "7d", Label: "7 days", Short: "7d"},
	{Flag: "until-revoked", Label: "until revoked", Short: "no expiry"},
}

// Toggling on defaults to a timed grant: an unbounded one has to be chosen.
const tunnelDefaultDuration = 1

func validateTunnelReport(report tunnelReport) error {
	if report.SchemaVersion != 1 {
		return fmt.Errorf("unsupported tunnel contract")
	}
	if len(report.Machines) == 0 {
		return fmt.Errorf("unsupported tunnel contract: the fleet registry is empty")
	}
	primaries := 0
	for _, machine := range report.Machines {
		if machine.Primary {
			primaries++
		}
	}
	if primaries != 1 {
		return fmt.Errorf("unsupported tunnel contract: %d primary keys", primaries)
	}
	return nil
}

func (m *model) loadTunnel() tea.Cmd {
	if m.tunnelLoading || m.tunnelMutating {
		return nil
	}
	m.tunnelLoading, m.tunnelErr = true, nil
	runner, cli := m.runner, m.cli
	return func() tea.Msg {
		out, err := runner.Output(context.Background(), cli, "tunnel", "list", "--json")
		if err != nil {
			return tunnelReportMsg{err: commandError("load fleet SSH access", out, err)}
		}
		var report tunnelReport
		if err := json.Unmarshal(out, &report); err != nil {
			return tunnelReportMsg{err: fmt.Errorf("decode fleet SSH access: %w", err)}
		}
		if err := validateTunnelReport(report); err != nil {
			return tunnelReportMsg{err: fmt.Errorf("decode fleet SSH access: %w", err)}
		}
		return tunnelReportMsg{report: report}
	}
}

// Run in the foreground: the CLI unlocks the vault on this terminal, and that
// prompt is the whole intentionality gate.
func (m *model) runTunnel(action, machine string, args ...string) tea.Cmd {
	if m.tunnelMutating {
		return nil
	}
	m.tunnelMutating, m.tunnelErr, m.tunnelAction = true, nil, action
	m.tunnelStatus = ""
	cmd := exec.Command(m.cli, append([]string{"tunnel", action, machine}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return tunnelActionMsg{action: action, machine: machine, err: err}
	})
}

func (m model) selectedTunnelMachine() (tunnelMachine, bool) {
	if m.tunnelCursor < 0 || m.tunnelCursor >= len(m.tunnel.Machines) {
		return tunnelMachine{}, false
	}
	return m.tunnel.Machines[m.tunnelCursor], true
}

func (m *model) tunnelUpdate(key string) tea.Cmd {
	if m.tunnelMutating {
		return nil
	}
	if m.tunnelPicking {
		switch key {
		case "left", "h":
			m.tunnelDuration = (m.tunnelDuration - 1 + len(tunnelDurations)) % len(tunnelDurations)
		case "right", "l":
			m.tunnelDuration = (m.tunnelDuration + 1) % len(tunnelDurations)
		case "enter", " ":
			machine, ok := m.selectedTunnelMachine()
			if !ok {
				m.tunnelPicking = false
				return nil
			}
			m.tunnelPicking = false
			return m.runTunnel("grant", machine.Name, "--for", tunnelDurations[m.tunnelDuration].Flag)
		case "esc", "n":
			m.tunnelPicking, m.tunnelStatus = false, "Cancelled — nothing changed."
		}
		return nil
	}
	switch key {
	case "up", "k":
		m.tunnelCursor = clampCursor(m.tunnelCursor-1, len(m.tunnel.Machines))
	case "down", "j":
		m.tunnelCursor = clampCursor(m.tunnelCursor+1, len(m.tunnel.Machines))
	case "r", "ctrl+r":
		m.tunnelLoading, m.tunnelStatus = false, ""
		return m.loadTunnel()
	case "enter", " ":
		machine, ok := m.selectedTunnelMachine()
		if !ok {
			return nil
		}
		// The registry's primary key is the machine's lockout protection, so the
		// panel refuses it here rather than letting the CLI refuse after an
		// unlock prompt has already implied the choice was available.
		if machine.Primary {
			m.tunnelStatus = machine.Name + " is the primary fleet key: it is always granted and can never be revoked here."
			return nil
		}
		if machine.Granted {
			return m.runTunnel("revoke", machine.Name)
		}
		m.tunnelPicking, m.tunnelDuration, m.tunnelStatus = true, tunnelDefaultDuration, ""
	}
	return nil
}

func (m *model) handleTunnelAction(msg tunnelActionMsg) tea.Cmd {
	m.tunnelMutating = false
	if msg.err != nil {
		m.tunnelErr = fmt.Errorf("tunnel %s %s failed: %w", msg.action, msg.machine, msg.err)
		m.tunnelLoading = false
		return m.loadTunnel()
	}
	if msg.action == "revoke" {
		m.tunnelStatus = "Revoked " + msg.machine + "."
	} else {
		m.tunnelStatus = "Granted " + msg.machine + "."
	}
	m.tunnelLoading = false
	return m.loadTunnel()
}

// Coarse on purpose: the exact deadline is in the rendered authorized_keys, and
// what an operator needs from a list is how much longer access lasts.
func tunnelRemaining(seconds int64) string {
	switch {
	case seconds <= 0:
		return "expired"
	case seconds < 60:
		return "under a minute"
	case seconds < 3600:
		return fmt.Sprintf("%dm", seconds/60)
	case seconds < 86400:
		return fmt.Sprintf("%dh %dm", seconds/3600, (seconds%3600)/60)
	default:
		return fmt.Sprintf("%dd %dh", seconds/86400, (seconds%86400)/3600)
	}
}

func tunnelStateSentence(machine tunnelMachine) string {
	switch machine.State {
	case "primary":
		return "always granted · primary"
	case "granted":
		return "granted until revoked"
	case "timed":
		remaining := "unknown"
		if machine.RemainingSeconds != nil {
			remaining = tunnelRemaining(*machine.RemainingSeconds)
		}
		if machine.ExpiresAt != nil {
			return fmt.Sprintf("granted · %s left · until %s", remaining,
				time.Unix(*machine.ExpiresAt, 0).Format("2006-01-02 15:04"))
		}
		return "granted · " + remaining + " left"
	case "expired":
		return "expired · sshd already refuses it"
	case "unmanaged":
		return "accepted today · not yet adopted"
	default:
		return "not granted"
	}
}

// The same facts in the space a 40-column pane has: state stays, prose goes.
// Truncating the full sentence instead would cut exactly the remaining time an
// operator opened this panel to read.
func tunnelCompactState(machine tunnelMachine) string {
	switch machine.State {
	case "primary":
		return "primary"
	case "granted":
		return "until revoked"
	case "timed":
		if machine.RemainingSeconds != nil {
			return tunnelRemaining(*machine.RemainingSeconds) + " left"
		}
		return "granted"
	case "expired":
		return "expired"
	case "unmanaged":
		return "unadopted"
	default:
		return "not granted"
	}
}

// Every option stays visible and selectable at every width: a clipped picker
// offers durations the operator cannot see. Prose labels degrade to short ones
// first, then the unselected cells give up their padding — the selected cell
// keeps its, because that padding is the highlight.
func (m model) tunnelDurationRow(width int) string {
	labels := make([]string, len(tunnelDurations))
	for index, duration := range tunnelDurations {
		labels[index] = duration.Label
	}
	// One cell in hand for the clipped-list scrollbar this row may sit beside.
	budget := width - 1
	padAll := true
	if tunnelDurationRowWidth(labels, padAll) > budget {
		for index, duration := range tunnelDurations {
			labels[index] = duration.Short
		}
		padAll = tunnelDurationRowWidth(labels, true) <= budget
	}
	cells := make([]string, 0, len(labels))
	for index, label := range labels {
		switch {
		case index == m.tunnelDuration:
			cells = append(cells, chipStyle.Render(label))
		case padAll:
			cells = append(cells, clikit.StDim.Render(" "+label+" "))
		default:
			cells = append(cells, clikit.StDim.Render(label))
		}
	}
	return strings.Join(cells, " ")
}

// Rendered width of a picker row: single-space joins, the selected cell always
// padded by one cell on both sides, the rest padded only when padAll.
func tunnelDurationRowWidth(labels []string, padAll bool) int {
	total := len(labels) - 1
	for _, label := range labels {
		total += lipgloss.Width(label)
	}
	if padAll {
		return total + 2*len(labels)
	}
	return total + 2
}

func (m model) tunnelRowsForWidth(width int) []string {
	if m.tunnelLoading {
		return []string{clikit.StDim.Render("Reading the fleet registry and this machine's grants…")}
	}
	if m.tunnelErr != nil {
		return []string{
			clikit.StBrk.Render("Fleet SSH access unavailable"),
			clikit.StDim.Render(ansi.Truncate(m.tunnelErr.Error(), width, "…")),
		}
	}
	rows := make([]string, 0, len(m.tunnel.Machines)+6)
	if m.tunnelStatus != "" {
		rows = append(rows, clikit.StOk.Render(ansi.Truncate(m.tunnelStatus, width, "…")), "")
	}
	nameWidth := 0
	for _, machine := range m.tunnel.Machines {
		nameWidth = max(nameWidth, len(machine.Name))
	}
	for index, machine := range m.tunnel.Machines {
		marker := " "
		if index == m.tunnelCursor {
			marker = ">"
		}
		state := tunnelStateSentence(machine)
		if width < 60 {
			state = tunnelCompactState(machine)
		}
		line := fmt.Sprintf("%s %-*s  %s", marker, nameWidth, machine.Name, state)
		if width >= 78 {
			line += "  " + clikit.StDim.Render(machine.Fingerprint)
		}
		rows = append(rows, ansi.Truncate(line, width, "…"))
	}
	if m.tunnelPicking {
		machine, _ := m.selectedTunnelMachine()
		note := "The vault unlocks before anything is written."
		if width < lipgloss.Width(note) {
			note = "Unlocks the vault first."
		}
		rows = append(rows, "",
			titleStyle.Render(ansi.Truncate("Grant "+machine.Name+" for", width, "…")),
			m.tunnelDurationRow(width),
			clikit.StDim.Render(note),
		)
		return rows
	}
	if m.tunnelMutating {
		rows = append(rows, "", clikit.StDim.Render("Running `atyrode tunnel "+m.tunnelAction+"` in the terminal…"))
		return rows
	}
	if width >= 78 {
		rows = append(rows, "",
			clikit.StDim.Render("registry  "+m.tunnel.RegistryPath),
			clikit.StDim.Render("rendered  "+m.tunnel.AuthorizedKeys),
		)
	}
	return rows
}

func (m model) tunnelFooter(width int) string {
	text := "↑↓ select  ·  Enter toggle grant  ·  r refresh"
	switch {
	case m.tunnelPicking && width < 60:
		text = "←/→ duration  ·  Enter grant  ·  Esc cancel"
	case m.tunnelPicking:
		text = "←/→ choose duration  ·  Enter grant (unlocks the vault)  ·  Esc cancel"
	case width < 60:
		text = "↑↓ select  ·  Enter toggle  ·  r refresh"
	}
	return clikit.ClipLines(clikit.StDim.Render(text), width)
}

func (m model) tunnelView(width int) string {
	bodyWidth := max(1, clikit.PanelContentWidth(width)-1)
	rows := m.tunnelRowsForWidth(max(1, bodyWidth-1))
	bodyHeight := min(max(1, len(rows)), m.workspaceBodyHeight())
	// The rows that matter are wherever the operator's attention is: the selected
	// machine while browsing, and the picker or progress note once one is open.
	// A short pane must scroll to those, never clip the only actionable control.
	rowCursor := m.tunnelCursor
	if m.tunnelStatus != "" {
		rowCursor += 2
	}
	if m.tunnelPicking || m.tunnelMutating {
		rowCursor = len(rows) - 1
	}
	body := clikit.WindowList(rows, rowCursor, bodyHeight, bodyWidth)
	panel := clikit.Panel(width, titleStyle.Render("Fleet SSH access to this machine")+"\n\n"+body)
	return strings.Join([]string{panel, m.tunnelFooter(width)}, "\n\n")
}
