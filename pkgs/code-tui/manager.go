package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
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

var errLoginCancelled = errors.New("login cancelled")

// loginProcess keeps upstream stderr buffered until the handoff finishes. OMP
// v17 can close readline while cancelling browser authentication, then print an
// ERR_USE_AFTER_CLOSE stack trace and exit non-zero. Treat that exact failure
// as cancellation; preserve every other diagnostic verbatim.
type loginProcess struct {
	cmd            *exec.Cmd
	stderr         bytes.Buffer
	terminalStderr io.Writer
}

func (p *loginProcess) SetStdin(r io.Reader)  { p.cmd.Stdin = r }
func (p *loginProcess) SetStdout(w io.Writer) { p.cmd.Stdout = w }
func (p *loginProcess) SetStderr(w io.Writer) { p.terminalStderr = w }

func (p *loginProcess) Run() error {
	p.cmd.Stderr = &p.stderr
	err := p.cmd.Run()
	diagnostic := p.stderr.String()
	if strings.Contains(diagnostic, "ERR_USE_AFTER_CLOSE") &&
		strings.Contains(diagnostic, "readline was closed") {
		return errLoginCancelled
	}
	if p.terminalStderr != nil && diagnostic != "" {
		_, _ = io.WriteString(p.terminalStderr, diagnostic)
	}
	return err
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
	p := &loginProcess{cmd: c}
	return tea.Exec(p, func(err error) tea.Msg {
		return loginDoneMsg{vault: v.ID, err: err}
	})
}

// updateManager handles keys while the vault manager is open. Every action is
// scoped to the manager; the generator keys stay inert until it closes.
func (m model) updateManager(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.loginRunning {
		return m, nil
	}
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
		cmd := m.loginCmd(m.mgrCursor, "anthropic")
		m.loginRunning = cmd != nil
		return m, cmd
	case "o":
		cmd := m.loginCmd(m.mgrCursor, "openai-codex")
		m.loginRunning = cmd != nil
		return m, cmd
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

	head := cursor + mark + labelCol
	if w < 38 {
		return head
	}
	indent := strings.Repeat(" ", 4)
	return strings.Join([]string{
		head,
		indent + m.vaultProviderLine(i, "anthropic"),
		indent + m.vaultProviderLine(i, "openai-codex"),
	}, "\n")
}

// vaultUsageSummary is the manager's compact per-provider usage cell: the
// highest-used window per provider, or a state word (disabled/loading/offline)
// when there is no usable data.
func (m model) vaultProviderLine(i int, provider string) string {
	v := m.vaults[i]
	line := providerHeading(provider, v)
	if !m.isEnabled(i) {
		return line + stDim.Render(" · disabled")
	}
	a, loaded := m.vaultUsage[v.ID]
	if !loaded {
		return line + stDim.Render(" · checking account…")
	}
	if !a.accountsOK {
		line += stWarn.Render(" · account status unavailable")
	} else if accounts := a.accounts[provider]; len(accounts) == 0 {
		line += stBrk.Render(" · not authenticated")
	} else {
		identities := make([]string, 0, len(accounts))
		for _, account := range accounts {
			identity := account.Email
			if identity == "" {
				identity = account.IdentityKey
			}
			if identity != "" {
				identities = append(identities, identity)
			}
		}
		switch {
		case len(identities) == 0:
			line += stDim.Render(" · authenticated")
		case len(identities) == 1:
			line += stDim.Render(" · " + identities[0])
		default:
			line += stDim.Render(" · " + strings.Join(identities, ", "))
		}
		if a.accountsStale {
			line += stWarn.Render(" · identity cached")
		}
	}

	if pct, ok := maxPct(a, provider); ok {
		usage := fmt.Sprintf(" · %d%% used", pct)
		switch {
		case pct >= 100:
			line += stBrk.Render(usage + " · maxed")
		case pct >= 80:
			line += stWarn.Render(usage + " · tight")
		default:
			line += stDim.Render(usage)
		}
	} else if !a.ok {
		line += stWarn.Render(" · usage unavailable")
	} else {
		line += stDim.Render(" · usage unavailable")
	}
	return line
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
	v := m.activeVault()
	if m.mgrCursor >= 0 && m.mgrCursor < len(m.vaults) {
		v = m.vaults[m.mgrCursor]
	}
	navigation := strings.Join([]string{
		cue("↑↓", "move"), cue("⏎", "select"), cue("space", "enable"),
		cue("r", "refresh"), cue("v", "close"),
	}, stDim.Render("  ·  "))
	login := strings.Join([]string{
		cue("c", "login Claude for "+v.Claude+" in profile "+v.Profile),
		cue("o", "login Codex for "+v.Codex+" in profile "+v.Profile),
	}, stDim.Render("  ·  "))
	if lipgloss.Width(navigation) <= w && lipgloss.Width(login) <= w {
		return navigation + "\n" + login
	}
	return strings.Join([]string{
		stKey.Render("↑↓"), stKey.Render("⏎"), stKey.Render("spc"),
		stKey.Render("r"), stKey.Render("c"), stKey.Render("o"), stKey.Render("v"),
	}, stDim.Render(" "))
}
