// code — the launcher picker, as a Bubble Tea TUI (replaces the fzf picker).
//
// Phase 1: a two-pane picker — a profile list on the left, the routing preview
// on the right (mouse-scrollable), launch on Enter. Data comes from a manifest
// the omp-configured package generates, so this binary stays generic:
//
//	CODE_PROFILES : TSV of  name \t blurb \t group \t exe-path
//	CODE_ROUTES   : the routes.plain page (role→model blocks, keyed by name)
//
// Later phases add the generator view, usage panel, and provider availability.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"syscall"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type profile struct {
	name, blurb, group, exe string
}

var (
	colDim     = lipgloss.NewStyle().Foreground(lipgloss.Color("#78829b"))
	colBold    = lipgloss.NewStyle().Bold(true)
	colAccent  = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff9f52"))
	colGroup   = lipgloss.NewStyle().Foreground(lipgloss.Color("#69727e"))
	selBar     = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff9f52")).Bold(true)
	paneBorder = lipgloss.NewStyle().Border(lipgloss.NormalBorder(), false, false, false, true).
			BorderForeground(lipgloss.Color("#3a4453")).PaddingLeft(2)
	title = lipgloss.NewStyle().Foreground(lipgloss.Color("#9aa4b1"))
)

type model struct {
	profiles []profile
	routes   map[string][]string
	cursor   int
	vp       viewport.Model
	w, h     int
	ready    bool
	chosen   string // exe to launch after quit
}

func loadProfiles(path string) ([]profile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []profile
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		parts := strings.Split(sc.Text(), "\t")
		if len(parts) < 4 {
			continue
		}
		out = append(out, profile{parts[0], parts[1], parts[2], parts[3]})
	}
	return out, sc.Err()
}

// parse routes.plain into name -> the profile's role rows (skipping the name and
// config header lines).
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
		if len(line) > 0 && line[0] != ' ' { // a name line: "<name>  <desc>"
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

func (m model) Init() tea.Cmd { return nil }

func (m *model) syncPreview() {
	if !m.ready {
		return
	}
	p := m.profiles[m.cursor]
	var b strings.Builder
	b.WriteString(colBold.Render(p.name) + "  " + colDim.Render(p.blurb) + "\n")
	b.WriteString(colDim.Render(strings.Repeat("─", 28)) + "\n")
	for _, r := range m.routes[p.name] {
		b.WriteString(r + "\n")
	}
	m.vp.SetContent(b.String())
	m.vp.GotoTop()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		listW := 40
		if m.w < 90 {
			listW = m.w / 3
		}
		if !m.ready {
			m.vp = viewport.New(m.w-listW-4, m.h-2)
			m.ready = true
		} else {
			m.vp.Width = m.w - listW - 4
			m.vp.Height = m.h - 2
		}
		m.syncPreview()
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
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(msg)
	return m, cmd
}

func (m model) View() string {
	if !m.ready {
		return "loading…"
	}
	listW := 40
	if m.w < 90 {
		listW = m.w / 3
	}
	var b strings.Builder
	lastGroup := ""
	for i, p := range m.profiles {
		if p.group != lastGroup {
			b.WriteString(colGroup.Render(p.group) + "\n")
			lastGroup = p.group
		}
		pointer := "  "
		name := p.name
		if i == m.cursor {
			pointer = selBar.Render("▌ ")
			name = colAccent.Render(name)
		} else {
			name = colBold.Render(name)
		}
		line := fmt.Sprintf("%s%-6s %s", pointer, name, colDim.Render(p.blurb))
		b.WriteString(lipgloss.NewStyle().Width(listW).MaxWidth(listW).Render(line) + "\n")
	}
	left := lipgloss.NewStyle().Width(listW).Render(b.String())
	right := paneBorder.Width(m.w - listW - 3).Render(m.vp.View())
	body := lipgloss.JoinHorizontal(lipgloss.Top, left, right)
	head := title.Render("  pick a launcher") + colDim.Render("   ↑/↓ move · enter launch · scroll preview · q quit")
	return head + "\n" + body
}

func main() {
	profiles, err := loadProfiles(os.Getenv("CODE_PROFILES"))
	if err != nil || len(profiles) == 0 {
		fmt.Fprintln(os.Stderr, "code: no profiles (CODE_PROFILES)")
		os.Exit(2)
	}
	routes := loadRoutes(os.Getenv("CODE_ROUTES"))
	m := model{profiles: profiles, routes: routes}
	prog := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	final, err := prog.Run()
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
