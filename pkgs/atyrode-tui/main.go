// atyrode-tui is the interactive cockpit for the scriptable atyrode CLI.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	previewdata "atyrode-tui/preview"
	clikit "cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type phase int

const (
	loadingPlan phase = iota
	loadingPreview
	ready
	confirming
	applying
	applied
	failed
)

type applyPlan struct {
	Host             string   `json:"host"`
	Installable      string   `json:"installable"`
	Source           string   `json:"source"`
	System           string   `json:"system"`
	User             string   `json:"user"`
	Capabilities     []string `json:"capabilities"`
	Backend          string   `json:"backend"`
	Revision         string   `json:"revision"`
	ResolvedRevision string   `json:"resolvedRevision"`
	Dirty            bool     `json:"dirty"`
	Repository       string   `json:"repository"`
	MutationBoundary string   `json:"mutationBoundary"`
}

type planMsg struct {
	plan applyPlan
	err  error
}

type previewMsg struct {
	preview previewdata.Document
	err     error
}

type applyDoneMsg struct{ err error }

type outputFunc func(string, ...string) ([]byte, error)
type applyFunc func(string, ...string) tea.Cmd

type model struct {
	cli     string
	output  outputFunc
	apply   applyFunc
	phase   phase
	plan    applyPlan
	preview previewdata.Document
	details bool
	cursor  int
	width   int
	height  int
	err     error
	status  string
}

func commandOutput(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).CombinedOutput()
}

func execApply(cli string, args ...string) tea.Cmd {
	cmd := exec.Command(cli, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return applyDoneMsg{err: err} })
}

func newModel(cli string) model {
	return model{
		cli:    cli,
		output: commandOutput,
		apply:  execApply,
		phase:  loadingPlan,
		width:  100,
		height: 30,
	}
}

func (m model) Init() tea.Cmd { return m.loadPlan() }

func (m model) loadPlan() tea.Cmd {
	return func() tea.Msg {
		out, err := m.output(m.cli, "apply", "--plan", "--json")
		if err != nil {
			return planMsg{err: commandError("load apply plan", out, err)}
		}
		var plan applyPlan
		if err := json.Unmarshal(out, &plan); err != nil {
			return planMsg{err: fmt.Errorf("decode apply plan: %w", err)}
		}
		if plan.Source == "remote" && !isFullGitRevision(plan.ResolvedRevision) {
			return planMsg{err: fmt.Errorf("decode apply plan: remote plan omitted its full resolved revision")}
		}
		return planMsg{plan: plan}
	}
}

func (m model) loadPreview() tea.Cmd {
	return func() tea.Msg {
		out, err := m.output(m.cli, m.applyArgs(true)...)
		if err != nil {
			return previewMsg{err: commandError("preview apply", out, err)}
		}
		var result previewdata.Document
		if err := json.Unmarshal(out, &result); err != nil {
			return previewMsg{err: fmt.Errorf("decode activation preview: %w", err)}
		}
		if result.SchemaVersion != previewdata.SchemaVersion {
			return previewMsg{err: fmt.Errorf("decode activation preview: unsupported schema version %d", result.SchemaVersion)}
		}
		if result.ResolvedRevision != m.plan.ResolvedRevision || result.Host != m.plan.Host || result.System != m.plan.System {
			return previewMsg{err: fmt.Errorf("decode activation preview: plan identity changed")}
		}
		return previewMsg{preview: result}
	}
}

func (m model) applyArgs(preview bool) []string {
	args := []string{"apply"}
	if m.plan.Source == "remote" {
		args = append(args, "--ref", m.plan.ResolvedRevision)
	}
	if preview {
		args = append(args, "--preview-json")
	}
	return args
}

func isFullGitRevision(revision string) bool {
	if len(revision) != 40 {
		return false
	}
	for _, c := range revision {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func commandError(action string, output []byte, err error) error {
	text := strings.TrimSpace(stripTerminalControls(strings.ReplaceAll(string(output), "\r", "\n")))
	if text == "" {
		return fmt.Errorf("%s: %w", action, err)
	}
	return fmt.Errorf("%s: %w\n%s", action, err, text)
}

// stripTerminalControls delegates ECMA-48 parsing (CSI, OSC, DCS, SOS, PM, APC,
// and their BEL/ST terminators) to Charm's ANSI parser. C0/C1 execution controls
// that are intentionally preserved by ansi.Strip are removed separately, except
// for whitespace used by the preview's line normalization.
func stripTerminalControls(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r == '\t' || r == '\n' || r == '\r':
			return r
		case r < 0x20 || (r >= 0x7f && r <= 0x9f):
			return -1
		default:
			return r
		}
	}, ansi.Strip(s))
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case planMsg:
		if msg.err != nil {
			m.phase, m.err = failed, msg.err
			return m, nil
		}
		m.plan, m.phase, m.err = msg.plan, loadingPreview, nil
		return m, m.loadPreview()
	case previewMsg:
		if msg.err != nil {
			m.phase, m.err = failed, msg.err
			return m, nil
		}
		m.preview = msg.preview
		m.phase, m.err, m.cursor, m.details = ready, nil, 0, false
		return m, nil
	case applyDoneMsg:
		if msg.err != nil {
			m.phase, m.err = failed, fmt.Errorf("apply failed: %w", msg.err)
		} else {
			m.phase, m.err, m.status = applied, nil, "Activation completed successfully."
		}
		return m, nil
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "r":
			if m.phase != applying {
				m.phase, m.err, m.status, m.preview, m.cursor, m.details = loadingPlan, nil, "", previewdata.Document{}, 0, false
				return m, m.loadPlan()
			}
		case "up", "k":
			if m.cursor > 0 {
				m.cursor--
			}
		case "down", "j":
			if m.cursor+1 < len(m.previewRows()) {
				m.cursor++
			}
		case "pgup":
			m.cursor -= m.previewHeight()
			if m.cursor < 0 {
				m.cursor = 0
			}
		case "pgdown":
			m.cursor += m.previewHeight()
			if m.cursor >= len(m.previewRows()) {
				m.cursor = len(m.previewRows()) - 1
			}
			if m.cursor < 0 {
				m.cursor = 0
			}
		case "d":
			if m.phase == ready || m.phase == confirming || m.phase == applied {
				m.details, m.cursor = !m.details, 0
			}
		case "a", "enter":
			if m.phase == ready {
				m.phase = confirming
			}
		case "y":
			if m.phase == confirming {
				m.phase, m.err = applying, nil
				return m, m.apply(m.cli, m.applyArgs(false)...)
			}
		case "n", "esc":
			if m.phase == confirming {
				m.phase = ready
			}
		}
	}
	return m, nil
}

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(clikit.CHead))
	pillStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#11151c")).Background(lipgloss.Color(clikit.CAcc)).Padding(0, 1)
	boxStyle   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color(clikit.CBord)).Padding(0, 1)
	labelStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(clikit.CDim)).Width(14)
	chipStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color(clikit.CHead)).Background(lipgloss.Color(clikit.CSelBg)).Padding(0, 1)
	iconStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color(clikit.CAcc))
)

func (m model) View() string {
	margin, panelWidth := m.horizontalLayout()

	sections := []string{
		titleStyle.Render("ATYRODE") + "  " + pillStyle.Render("apply"),
		m.header(panelWidth),
		m.previewBox(panelWidth),
		m.footer(),
	}
	return clikit.PadLeft(strings.Join(sections, "\n\n"), margin)
}

func (m model) horizontalLayout() (margin, panelWidth int) {
	margin = 2
	if m.width < 44 {
		margin = 1
	}
	panelWidth = m.width - 2*margin - 4 // keep borders clear of the terminal auto-wrap column
	if panelWidth < 1 {
		panelWidth = 1
	}
	return margin, panelWidth
}

func (m model) header(width int) string {
	if m.plan.Host == "" {
		if m.phase == failed {
			return panel(width, clikit.StBrk.Render("Unable to load apply plan"))
		}
		return panel(width, clikit.StDim.Render("Resolving host and apply plan…"))
	}

	dirty := clikit.StOk.Render("clean")
	if m.plan.Dirty {
		dirty = clikit.StWarn.Render("dirty")
	}
	available := panelContentWidth(width)
	targetWidth := available - lipgloss.Width(labelStyle.Render("target")) - 2
	if targetWidth < 1 {
		targetWidth = 1
	}
	target := ansi.Truncate(m.plan.Installable, targetWidth, "")
	compactTarget := ansi.Truncate(m.plan.Installable, available-2, "")
	var lines []string
	system := m.plan.System
	if width >= 50 {
		system += "  ·  " + m.plan.User
	}
	if width < 50 {
		lines = []string{
			iconStyle.Render("\uf108") + "  " + titleStyle.Render(m.plan.Host),
			labelStyle.Render("system") + clikit.StDim.Render(system),
			labelStyle.Render("capabilities") + capabilityChips(m.plan.Capabilities, available-14),
		}
	} else if width < 80 {
		lines = []string{
			iconStyle.Render("\uf108") + "  " + titleStyle.Render(m.plan.Host),
			labelStyle.Render("system") + clikit.StDim.Render(system),
			labelStyle.Render("target"),
			clikit.StHead.Render("  " + compactTarget),
			labelStyle.Render("revision") + m.plan.Revision,
			labelStyle.Render("capabilities") + capabilityChips(m.plan.Capabilities, available-14),
		}
	} else {
		lines = []string{
			iconStyle.Render("\uf108") + "  " + titleStyle.Render(m.plan.Host) + clikit.StDim.Render("  "+m.plan.System+"  ·  "+m.plan.User),
			"",
			labelStyle.Render("target") + clikit.StHead.Render(target),
			labelStyle.Render("revision") + m.plan.Revision + clikit.StDim.Render("  ·  "+m.plan.Source+"  ·  "+m.plan.Backend+"  ·  ") + dirty,
			labelStyle.Render("capabilities") + capabilityChips(m.plan.Capabilities, available-14),
		}
	}
	return panel(width, strings.Join(lines, "\n"))
}

func panel(width int, content string) string {
	if width < 1 {
		width = 1
	}
	inner := panelContentWidth(width)
	content = clipLines(content, inner)
	return boxStyle.Width(inner).Render(content)
}

func clipLines(content string, width int) string {
	lines := strings.Split(content, "\n")
	for i := range lines {
		lines[i] = ansi.Truncate(lines[i], width, "")
	}
	return strings.Join(lines, "\n")
}

func panelContentWidth(width int) int {
	inner := width - boxStyle.GetHorizontalFrameSize() - 2 // padding is outside lipgloss Width
	if inner < 1 {
		return 1
	}
	return inner
}

func capabilityChips(capabilities []string, width int) string {
	if len(capabilities) == 0 {
		return clikit.StDim.Render("none")
	}
	if width < 32 {
		return chipStyle.Render(fmt.Sprintf("%d active", len(capabilities)))
	}
	if width < 1 {
		width = 1
	}
	var lines []string
	current := ""
	for _, capability := range capabilities {
		chip := chipStyle.Render(capability)
		next := chip
		if current != "" {
			next = current + " " + chip
		}
		if current != "" && lipgloss.Width(next) > width {
			lines = append(lines, current)
			current = chip
		} else {
			current = next
		}
	}
	if current != "" {
		lines = append(lines, current)
	}
	return strings.Join(lines, "\n"+strings.Repeat(" ", 14))
}

func (m model) previewHeight() int {
	_, width := m.horizontalLayout()
	// Three blank separators plus the title, preview border/title, footer, and
	// two terminal auto-wrap safety rows consume ten rows. Measuring the rendered
	// header keeps narrow layouts from pushing the title into scrollback.
	fixedRows := lipgloss.Height(m.header(width)) + lipgloss.Height(m.footer()) + 10
	h := m.height - fixedRows
	if h < 1 {
		h = 1
	}
	return h
}

func (m model) previewBox(width int) string {
	var body string
	switch m.phase {
	case loadingPlan:
		body = clikit.StDim.Render("Loading apply plan…")
	case loadingPreview:
		body = clikit.StDim.Render("Building read-only activation preview…")
	case applying:
		body = clikit.StWarn.Render("Apply is running in the terminal…")
	default:
		if m.preview.SchemaVersion == 0 {
			body = clikit.StDim.Render("Preview unavailable.")
		} else {
			previewWidth := panelContentWidth(width) - 4
			if previewWidth < 1 {
				previewWidth = 1
			}
			body = clikit.WindowList(m.previewRowsForWidth(max(1, previewWidth-1)), m.cursor, m.previewHeight(), previewWidth)
		}
	}
	label := iconStyle.Render("\uf0ad") + "  " + titleStyle.Render("ACTIVATION PREVIEW") + "\n"
	return panel(width, label+body)
}

func (m model) previewRows() []string {
	_, width := m.horizontalLayout()
	previewWidth := panelContentWidth(width) - 4
	if previewWidth < 1 {
		previewWidth = 1
	}
	return m.previewRowsForWidth(max(1, previewWidth-1))
}

func (m model) previewRowsForWidth(width int) []string {
	rows := make([]string, 0, 24)
	revision := m.preview.ResolvedRevision
	if len(revision) > 12 {
		revision = revision[:12]
	}
	if width < 32 {
		appendWrappedRow(&rows, "Applying "+titleStyle.Render(revision), width)
		appendWrappedRow(&rows, "will make these changes.", width)
	} else {
		appendWrappedRow(&rows, "Applying revision "+titleStyle.Render(revision)+" will make the following changes.", width)
	}
	rows = append(rows, "")

	status := "✓  Preview built"
	if m.preview.Status == "no-changes" {
		status += " · no version or size changes"
	}
	appendWrappedRow(&rows, clikit.StOk.Render(status), width)
	if m.details {
		rows = append(rows, "")
		appendWrappedRow(&rows, titleStyle.Render("Technical details"), width)
		if generations := m.preview.Generations; generations != nil {
			if generations.Previous != "" {
				appendWrappedRow(&rows, clikit.StHead.Render("Previous generation"), width)
				appendIndentedWrappedRow(&rows, clikit.StDim.Render(generations.Previous), width, 2)
			}
			if generations.New != "" {
				appendWrappedRow(&rows, clikit.StHead.Render("New generation"), width)
				appendIndentedWrappedRow(&rows, clikit.StDim.Render(generations.New), width, 2)
			}
		}
		raw := make([]string, 0, len(m.preview.Technical))
		for _, line := range m.preview.Technical {
			if strings.HasPrefix(line, "<<< ") || strings.HasPrefix(line, ">>> ") {
				continue
			}
			raw = append(raw, line)
		}
		if len(raw) > 0 {
			rows = append(rows, "")
			appendWrappedRow(&rows, titleStyle.Render("Normalized nh report"), width)
			for _, line := range raw {
				appendIndentedWrappedRow(&rows, clikit.StDim.Render(line), width, 2)
			}
		}
		return rows
	}

	added, updated, removed := len(m.preview.Packages.Added), len(m.preview.Packages.Updated), len(m.preview.Packages.Removed)
	var packageFacts []string
	if added > 0 {
		packageFacts = append(packageFacts, fmt.Sprintf("%d added", added))
	}
	if updated > 0 {
		packageFacts = append(packageFacts, fmt.Sprintf("%d updated", updated))
	}
	if removed > 0 {
		packageFacts = append(packageFacts, fmt.Sprintf("%d removed", removed))
	}
	if len(packageFacts) == 0 {
		appendWrappedRow(&rows, labelStyle.Render("Packages")+clikit.StDim.Render("No package changes reported."), width)
	} else {
		appendWrappedRow(&rows, labelStyle.Render("Packages")+strings.Join(packageFacts, "  ·  "), width)
	}
	if paths := m.preview.StorePaths; paths != nil {
		facts := fmt.Sprintf("%s added  ·  %s removed", formatCount(paths.Added), formatCount(paths.Removed))
		appendWrappedRow(&rows, labelStyle.Render("Store paths")+facts, width)
	}
	if closure := m.preview.Closure; closure != nil {
		if closure.Delta != "" {
			appendWrappedRow(&rows, diskUsageSentence(closure.Delta), width)
		}
		if closure.Resulting != "" {
			appendWrappedRow(&rows, "Resulting total closure size is "+clikit.StHead.Render(closure.Resulting)+".", width)
		}
	}

	groups := []struct {
		name    string
		changes []previewdata.PackageChange
		style   lipgloss.Style
	}{
		{name: "Added", changes: m.preview.Packages.Added, style: clikit.StOk},
		{name: "Updated", changes: m.preview.Packages.Updated, style: clikit.StHead},
		{name: "Removed", changes: m.preview.Packages.Removed, style: clikit.StBrk},
	}
	for _, group := range groups {
		if len(group.changes) == 0 {
			continue
		}
		rows = append(rows, "")
		appendWrappedRow(&rows, group.style.Bold(true).Render(fmt.Sprintf("%s (%d)", group.name, len(group.changes))), width)
		for _, change := range group.changes {
			appendIndentedWrappedRow(&rows, titleStyle.Render(change.Name), width, 2)
			if secondary := packageSecondary(change); secondary != "" {
				appendIndentedWrappedRow(&rows, clikit.StDim.Render(secondary), width, 4)
			}
		}
	}

	return rows
}

func appendWrappedRow(rows *[]string, line string, width int) {
	for _, wrapped := range strings.Split(ansi.Wrap(line, width, " "), "\n") {
		*rows = append(*rows, wrapped)
	}
}

func appendIndentedWrappedRow(rows *[]string, line string, width, indent int) {
	contentWidth := max(1, width-indent)
	prefix := strings.Repeat(" ", indent)
	for _, wrapped := range strings.Split(ansi.Wrap(line, contentWidth, " "), "\n") {
		*rows = append(*rows, prefix+wrapped)
	}
}

func packageSecondary(change previewdata.PackageChange) string {
	var details []string
	switch {
	case change.PreviousVersion != "" && change.NewVersion != "":
		details = append(details, change.PreviousVersion+" → "+change.NewVersion)
	case change.NewVersion != "":
		details = append(details, change.NewVersion)
	case change.PreviousVersion != "":
		details = append(details, change.PreviousVersion)
	}
	if change.SizeDelta != "" {
		details = append(details, change.SizeDelta)
	}
	return strings.Join(details, "  ·  ")
}

func diskUsageSentence(delta string) string {
	switch {
	case strings.HasPrefix(delta, "-"):
		return "Disk usage decreases by " + clikit.StOk.Render(strings.TrimPrefix(delta, "-")) + "."
	case strings.HasPrefix(delta, "+"):
		return "Disk usage increases by " + clikit.StWarn.Render(strings.TrimPrefix(delta, "+")) + "."
	default:
		return "Disk usage is unchanged (" + delta + ")."
	}
}

func formatCount(value int) string {
	digits := strconv.Itoa(value)
	for i := len(digits) - 3; i > 0; i -= 3 {
		digits = digits[:i] + "," + digits[i:]
	}
	return digits
}

const maxErrorLines = 4

func (m model) errorFooter() string {
	_, width := m.horizontalLayout()
	if width < 1 {
		width = 1
	}
	text := clikit.StBrk.Render(stripTerminalControls(m.err.Error()))
	lines := strings.Split(ansi.Hardwrap(text, width, false), "\n")
	if len(lines) > maxErrorLines {
		lines = lines[:maxErrorLines]
		tailWidth := width - 1
		if tailWidth < 1 {
			tailWidth = 1
		}
		lines[maxErrorLines-1] = ansi.Truncate(lines[maxErrorLines-1], tailWidth, "") + "…"
	}
	lines = append(lines, clikit.StDim.Render("r retry  ·  q quit"))
	return strings.Join(lines, "\n")
}

func (m model) footer() string {
	if m.err != nil {
		return m.errorFooter()
	}
	mode := "details"
	if m.details {
		mode = "summary"
	}
	switch m.phase {
	case confirming:
		if m.width < 60 {
			return clikit.StWarn.Render("Apply?  y confirm  ·  n cancel  ·  d " + mode)
		}
		return clikit.StWarn.Render("Apply this configuration?  y confirm  ·  n cancel  ·  d " + mode)
	case applying:
		return clikit.StDim.Render("Applying…")
	case applied:
		return clikit.StOk.Render(m.status) + "\n" + clikit.StDim.Render("d "+mode+"  ·  r refresh  ·  q quit")
	case ready:
		if m.width < 60 {
			return clikit.StDim.Render("d " + mode + "  ·  enter apply  ·  q quit")
		}
		return clikit.StDim.Render("↑/↓ preview  ·  d " + mode + "  ·  a/enter apply  ·  r refresh  ·  q quit")
	default:
		return clikit.StDim.Render("q quit")
	}
}

func main() {
	cli := os.Getenv("ATYRODE_CLI")
	if cli == "" {
		cli = "atyrode"
	}
	if _, err := clikit.Run(newModel(cli), clikit.WithAltScreen()); err != nil {
		fmt.Fprintln(os.Stderr, "atyrode cockpit:", err)
		os.Exit(1)
	}
}
