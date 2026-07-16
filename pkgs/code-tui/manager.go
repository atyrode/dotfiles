package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// loginDoneMsg reports that a suspended login handoff for a vault has finished.
type loginDoneMsg struct {
	vault string
	err   error
}

// loginCmd suspends Bubble Tea and runs the plain-OMP login handoff for the
// cursored vault in the terminal, then reports completion so the vault can be
// refreshed. Login reaches the vault's OWN profile store (never the shared
// default) because it establishes the credentials the broker later serves.
func (m model) loginCmd(i int, provider string) tea.Cmd {
	if i < 0 || i >= len(m.vaults) {
		return nil
	}
	v := m.vaults[i]
	raw := os.Getenv("CODE_OMP_RAW")
	if raw == "" {
		raw = "omp"
	}
	c := exec.Command(raw, loginArgv(v.Profile, provider)...)
	return tea.ExecProcess(c, func(err error) tea.Msg {
		return loginDoneMsg{vault: v.ID, err: err}
	})
}

// updateManager handles keys while the vault manager is open. Every action is
// scoped to the manager; the generator keys stay inert until it closes.
func (m model) updateManager(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc", "v":
		m.manager = false
		m.relayout()
		return m, nil
	case "up", "k":
		if m.mgrCursor > 0 {
			m.mgrCursor--
		}
		return m, nil
	case "down", "j":
		if m.mgrCursor < len(m.vaults)-1 {
			m.mgrCursor++
		}
		return m, nil
	case "enter":
		prev := m.selected
		if _, err := m.activateVault(m.mgrCursor); err != nil {
			m.vaultErr = err.Error()
			return m, nil
		}
		m.vaultErr = ""
		return m, m.afterSelectionChange(prev)
	case " ":
		prev := m.selected
		if _, err := m.toggleVault(m.mgrCursor); err != nil {
			m.vaultErr = err.Error()
			return m, nil
		}
		m.vaultErr = ""
		return m, m.afterSelectionChange(prev)
	case "r":
		m.fetching = m.usageCmd != ""
		return m, fetchAllCmd(m.usageCmd, m.vaults)
	case "c":
		return m, m.loginCmd(m.mgrCursor, "anthropic")
	case "o":
		return m, m.loginCmd(m.mgrCursor, "openai-codex")
	}
	return m, nil
}

// afterSelectionChange re-fetches the detailed panel's usage when the active
// vault moved, so closing the manager lands on the right identity's data.
func (m *model) afterSelectionChange(prev string) tea.Cmd {
	if m.selected == prev || m.usageCmd == "" {
		return nil
	}
	m.fetching = true
	return fetchUsageCmd(m.usageCmd, m.activeVault())
}

// managerView renders the collapsed-by-default full-screen vault manager: a
// row per vault with its enabled/selected/offline state and compact
// per-provider usage, over a pinned control rule. Overflow is clipped to the
// terminal bounds, so the footer can never be pushed off-screen.
func (m model) managerView() string {
	title := padLeft(m.pill("vaults")+"  "+stCue.Render("isolated auth vaults · the trusted profile stays shared"), gut)
	lines := []string{title, ""}
	for i := range m.vaults {
		lines = append(lines, padLeft(m.managerRow(i, m.w-gut), gut))
	}
	if m.vaultErr != "" {
		lines = append(lines, "", padLeft(stBrk.Render(m.vaultErr), gut))
	}
	body := strings.Join(lines, "\n")

	controls := padLeft(m.managerControls(m.w-gut), gut)
	rule := stDim.Render(strings.Repeat("─", m.w))
	ch := m.h - lipgloss.Height(controls) - lipgloss.Height(rule) - topGap
	if ch < 1 {
		ch = 1
	}
	placed := lipgloss.Place(m.w, ch, lipgloss.Left, lipgloss.Top,
		strings.Repeat("\n", topGap)+body)
	return lipgloss.NewStyle().MaxWidth(m.w).MaxHeight(m.h).Render(
		lipgloss.JoinVertical(lipgloss.Left, placed, rule, controls))
}

// managerRow renders one vault: cursor + state mark + label, then (when the
// width seats it) the backing accounts, then the compact usage summary.
func (m model) managerRow(i, w int) string {
	v := m.vaults[i]
	acc := m.accent()

	cursor := "  "
	if i == m.mgrCursor {
		cursor = lipgloss.NewStyle().Foreground(lipgloss.Color(acc)).Render("▸ ")
	}
	var mark string
	switch {
	case v.ID == m.selected:
		mark = lipgloss.NewStyle().Foreground(lipgloss.Color(cGreen)).Render("● ")
	case !m.isEnabled(i):
		mark = stDim.Render("· ")
	default:
		mark = stDim.Render("○ ")
	}

	label := v.Label
	if label == "" {
		label = v.ID
	}
	labelPlain := pad(label, 10)
	var labelCol string
	switch {
	case !m.isEnabled(i):
		labelCol = stStruck.Render(labelPlain)
	case v.ID == m.selected:
		labelCol = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(cHead)).Render(labelPlain)
	default:
		labelCol = stHead.Render(labelPlain)
	}

	usage := m.vaultUsageSummary(i)
	left := cursor + mark + labelCol
	// cursor(2)+mark(2)+label(10)=14; identity column is a fixed 26 cells.
	const identW = 26
	ident := stDim.Render(pad("Claude "+v.Claude+" · Codex "+v.Codex, identW))
	if 14+2+identW+2+lipgloss.Width(usage) <= w {
		return left + "  " + ident + "  " + usage
	}
	return left + "  " + usage
}

// vaultUsageSummary is the manager's compact per-provider usage cell: the
// highest-used window per provider, or a state word (disabled/loading/offline)
// when there is no usable data.
func (m model) vaultUsageSummary(i int) string {
	if !m.isEnabled(i) {
		return stDim.Render("disabled")
	}
	a, ok := m.vaultUsage[m.vaults[i].ID]
	if !ok {
		return stDim.Render("loading…")
	}
	if !a.ok {
		return stWarn.Render("offline")
	}
	var parts []string
	if pct, has := maxPct(a, "openai-codex"); has {
		parts = append(parts, provCell("Codex", pct))
	}
	if pct, has := maxPct(a, "anthropic"); has {
		parts = append(parts, provCell("Claude", pct))
	}
	if len(parts) == 0 {
		return stDim.Render("no usage")
	}
	return strings.Join(parts, stDim.Render(" · "))
}

// provCell renders one provider's compact "<name> NN%" figure, tinted to warn
// as the window fills so a hot vault is legible at a glance.
func provCell(name string, pct int) string {
	fig := fmt.Sprintf("%s %d%%", name, pct)
	switch {
	case pct >= 100:
		return stBrk.Render(fig)
	case pct >= 80:
		return stWarn.Render(fig)
	default:
		return stDim.Render(fig)
	}
}

// maxPct returns the highest used percentage across a provider's windows, and
// whether the provider was present in the payload at all.
func maxPct(a availability, prov string) (int, bool) {
	max, has := 0, false
	for _, w := range a.wins {
		if w.prov != prov {
			continue
		}
		has = true
		if w.pct > max {
			max = w.pct
		}
	}
	return max, has
}

// managerControls is the manager's bottom cue row. It drops to keys-only when
// the labelled form would not fit the width, keeping the footer within bounds.
func (m model) managerControls(w int) string {
	cue := func(k, label string) string { return stKey.Render(k) + stDim.Render(" "+label) }
	full := strings.Join([]string{
		cue("↑↓", "move"), cue("⏎", "activate"), cue("space", "enable"),
		cue("r", "refresh"), cue("c", "claude login"), cue("o", "codex login"),
		cue("v", "close"),
	}, stDim.Render("  ·  "))
	if lipgloss.Width(full) <= w {
		return full
	}
	return strings.Join([]string{
		stKey.Render("↑↓"), stKey.Render("⏎"), stKey.Render("spc"),
		stKey.Render("r"), stKey.Render("c"), stKey.Render("o"), stKey.Render("v"),
	}, stDim.Render(" "))
}
