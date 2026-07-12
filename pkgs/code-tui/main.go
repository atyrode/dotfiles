// code — the launcher picker, as a Bubble Tea TUI (replaces the fzf picker).
//
// Data comes from a manifest omp-configured generates, so this binary stays
// generic:
//
//	CODE_PROFILES : TSV of  name \t blurb \t group \t exe \t colorHex \t glyph
//	CODE_ROUTES   : the routes.plain page (role→model blocks, keyed by name)
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
	"syscall"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type profile struct {
	name, blurb, group, exe, color, glyph string
}

const (
	cDim  = "#78829b"
	cGrp  = "#69727e"
	cAcc  = "#ff9f52"
	cBord = "#3a4453"
	cHead = "#9aa4b1"
)

var (
	stDim   = lipgloss.NewStyle().Foreground(lipgloss.Color(cDim))
	stGrp   = lipgloss.NewStyle().Foreground(lipgloss.Color(cGrp))
	stBold  = lipgloss.NewStyle().Bold(true)
	stHead  = lipgloss.NewStyle().Foreground(lipgloss.Color(cHead))
	stPtr   = lipgloss.NewStyle().Foreground(lipgloss.Color(cAcc)).Bold(true)
	modelRe = regexp.MustCompile(`(gpt|claude)[A-Za-z0-9._-]*:(minimal|low|medium|high|xhigh|max)`)
)

// ── routing colorizer (port of colorize_routes) ──────────────────────────────
func lvl(s string) int {
	switch s {
	case "minimal":
		return 0
	case "low":
		return 1
	case "medium":
		return 2
	case "high":
		return 3
	case "xhigh":
		return 4
	default:
		return 5
	}
}

func shortModel(name string) string {
	if name == "gpt-5.4" {
		return name
	}
	parts := strings.Split(name, "-")
	if strings.HasPrefix(name, "claude") && len(parts) > 1 {
		return parts[1]
	}
	return parts[len(parts)-1]
}

func clamp(x float64) int {
	v := int(x)
	if v > 255 {
		return 255
	}
	if v < 0 {
		return 0
	}
	return v
}

func paintModel(tok string) string {
	i := strings.LastIndex(tok, ":")
	name, level := tok[:i], tok[i+1:]
	var br, bg, bb float64
	if strings.HasPrefix(tok, "gpt") {
		br, bg, bb = 110, 170, 240
	} else {
		br, bg, bb = 240, 160, 105
	}
	f := 0.60 + float64(lvl(level))*0.088
	col := lipgloss.Color(fmt.Sprintf("#%02x%02x%02x", clamp(br*f), clamp(bg*f), clamp(bb*f)))
	return lipgloss.NewStyle().Foreground(col).Render(shortModel(name) + ":" + level)
}

func colorizeLine(line string) string {
	// dim the arrows and role scaffolding, colour the model tokens.
	line = modelRe.ReplaceAllStringFunc(line, paintModel)
	return line
}

// ── data loading ─────────────────────────────────────────────────────────────
func loadProfiles(path string) []profile {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []profile
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		p := strings.Split(sc.Text(), "\t")
		for len(p) < 6 {
			p = append(p, "")
		}
		out = append(out, profile{p[0], p[1], p[2], p[3], p[4], p[5]})
	}
	return out
}

func loadRoutes(path string) map[string][]string {
	routes := map[string][]string{}
	f, err := os.Open(path)
	if err != nil {
		return routes
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	var cur string
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			cur = ""
			continue
		}
		if line[0] != ' ' {
			fields := strings.Fields(line)
			if len(fields) > 0 {
				cur = fields[0]
				routes[cur] = nil
			}
			continue
		}
		if cur != "" {
			routes[cur] = append(routes[cur], line)
		}
	}
	return routes
}

// ── model ────────────────────────────────────────────────────────────────────
type model struct {
	profiles []profile
	routes   map[string][]string
	cursor   int
	vp       viewport.Model
	w, h     int
	ready    bool
	chosen   string
}

func listWidth(w int) int {
	if w < 96 {
		return w / 3
	}
	return 42
}

func (m model) Init() tea.Cmd { return nil }

func (m *model) syncPreview() {
	if !m.ready {
		return
	}
	p := m.profiles[m.cursor]
	var b strings.Builder
	name := lipgloss.NewStyle().Foreground(lipgloss.Color(p.color)).Bold(true).Render(p.name)
	b.WriteString(name + "  " + stDim.Render(p.blurb) + "\n")
	b.WriteString(stDim.Render("── routing ─────────────────") + "\n")
	for _, r := range m.routes[p.name] {
		b.WriteString(colorizeLine(r) + "\n")
	}
	m.vp.SetContent(b.String())
	m.vp.GotoTop()
}

func (m *model) relayout() {
	lw := listWidth(m.w)
	pw := m.w - lw - 3
	if pw < 10 {
		pw = 10
	}
	if !m.ready {
		m.vp = viewport.New(pw, m.h-2)
		m.ready = true
	} else {
		m.vp.Width, m.vp.Height = pw, m.h-2
	}
	m.syncPreview()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.relayout()
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
				m.syncPreview()
			}
		case "down", "j":
			if m.cursor < len(m.profiles)-1 {
				m.cursor++
				m.syncPreview()
			}
		case "enter":
			m.chosen = m.profiles[m.cursor].exe
			return m, tea.Quit
		}
	case tea.MouseMsg:
		switch msg.Button {
		case tea.MouseButtonWheelUp:
			m.vp.LineUp(3)
		case tea.MouseButtonWheelDown:
			m.vp.LineDown(3)
		}
	}
	return m, nil
}

func (m model) View() string {
	if !m.ready {
		return "loading…"
	}
	lw := listWidth(m.w)
	trunc := lipgloss.NewStyle().MaxWidth(lw).Inline(true)

	var b strings.Builder
	lastGroup := ""
	for i, p := range m.profiles {
		if p.group != lastGroup {
			b.WriteString(stGrp.Render(p.group) + "\n")
			lastGroup = p.group
		}
		ptr := "  "
		if i == m.cursor {
			ptr = stPtr.Render("▌ ")
		}
		gly := lipgloss.NewStyle().Foreground(lipgloss.Color(p.color)).Render(p.glyph)
		nm := p.name
		if i == m.cursor {
			nm = lipgloss.NewStyle().Foreground(lipgloss.Color(cAcc)).Bold(true).Render(nm)
		} else {
			nm = lipgloss.NewStyle().Foreground(lipgloss.Color(p.color)).Bold(true).Render(nm)
		}
		row := fmt.Sprintf("%s%s %-6s %s", ptr, gly, nm, stDim.Render(p.blurb))
		b.WriteString(trunc.Render(row) + "\n")
	}
	left := lipgloss.NewStyle().Width(lw).Render(b.String())
	rightPane := lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(lipgloss.Color(cBord)).PaddingLeft(2).
		Width(m.w - lw - 3).Height(m.h - 1).
		Render(m.vp.View())
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, rightPane)
	head := stHead.Render("  pick a launcher") +
		stDim.Render("    ↑/↓ move · enter launch · wheel scrolls preview · q quit")
	return head + "\n" + body
}

func main() {
	profiles := loadProfiles(os.Getenv("CODE_PROFILES"))
	if len(profiles) == 0 {
		fmt.Fprintln(os.Stderr, "code: no profiles (CODE_PROFILES)")
		os.Exit(2)
	}
	m := model{profiles: profiles, routes: loadRoutes(os.Getenv("CODE_ROUTES"))}
	final, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "code:", err)
		os.Exit(1)
	}
	if fm, ok := final.(model); ok && fm.chosen != "" {
		args := append([]string{fm.chosen}, os.Args[1:]...)
		if err := syscall.Exec(fm.chosen, args, os.Environ()); err != nil {
			fmt.Fprintln(os.Stderr, "code: exec:", err)
			os.Exit(1)
		}
	}
}
