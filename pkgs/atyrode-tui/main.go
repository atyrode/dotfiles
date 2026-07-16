// atyrode-tui is the interactive cockpit for the scriptable atyrode CLI.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"

	inventorydata "atyrode-tui/inventory"
	previewdata "atyrode-tui/preview"
	clikit "cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

type phase int

const (
	loadingPlan phase = iota
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
	revision   string
	generation uint64
	preview    previewdata.Document
	err        error
}
type inventoryMsg struct {
	revision   string
	generation uint64
	inventory  inventorydata.Document
	err        error
	diagnostic string
}

type pane int

const (
	previewPane pane = iota
	capabilityPane
)

type applyDoneMsg struct{ err error }

type commandRunner interface {
	Output(context.Context, string, ...string) ([]byte, error)
}

type execCommandRunner struct{}

func (execCommandRunner) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if stdout.Len() > 0 {
		if err != nil && stderr.Len() > 0 {
			err = fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
		}
		return stdout.Bytes(), err
	}
	return stderr.Bytes(), err
}

type applyFunc func(string, ...string) tea.Cmd

type askGroundingFunc func(context.Context, string) ([]byte, error)

type groundedAsker struct {
	cli       string
	grounding askGroundingFunc
	backend   func(clikit.DocCorpus) clikit.Asker

	mu   sync.Mutex
	docs clikit.DocCorpus
}

func (a *groundedAsker) Ask(ctx context.Context, prompt string) (<-chan string, error) {
	docs, err := a.loadDocs(ctx)
	if err != nil {
		return nil, err
	}
	return a.backend(docs).Ask(ctx, prompt)
}

func (a *groundedAsker) loadDocs(ctx context.Context) (clikit.DocCorpus, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.docs != "" {
		return a.docs, nil
	}
	help, err := a.grounding(ctx, a.cli)
	if err != nil {
		return "", commandError("load atyrode command reference", help, err)
	}
	docs, err := buildAskGrounding(help)
	if err != nil {
		return "", err
	}
	a.docs = docs
	return docs, nil
}

func commandGrounding(ctx context.Context, cli string) ([]byte, error) {
	return exec.CommandContext(ctx, cli, "--help").CombinedOutput()
}

func buildAskGrounding(help []byte) (clikit.DocCorpus, error) {
	reference := strings.TrimSpace(stripTerminalControls(string(help)))
	if reference == "" || !strings.Contains(reference, "Usage:") || !strings.Contains(reference, "atyrode ") {
		return "", fmt.Errorf("load atyrode command reference: --help returned no recognizable usage")
	}
	return clikit.DocCorpus("You are atyrode's read-only Ask assistant. Answer questions about atyrode only from the command reference below. Never claim to execute commands or change the system. Do not invent commands, flags, behavior, or help forms. Suggest only exact invocations supported by the reference. If the reference does not answer a question, say that it is not documented and stop; do not suggest other commands or sources.\n\nCommand reference (from `atyrode --help`):\n" + reference), nil
}

type model struct {
	cli            string
	runner         commandRunner
	apply          applyFunc
	asker          clikit.Asker
	nav            clikit.WorkspaceNav
	phase          phase
	plan           applyPlan
	applyRequested bool

	preview             previewdata.Document
	previewLoading      bool
	previewErr          error
	previewGeneration   uint64
	previewCancel       context.CancelFunc
	inventory           inventorydata.Document
	inventoryRequested  bool
	inventoryLoading    bool
	inventoryErr        error
	inventoryGeneration uint64
	inventoryCancel     context.CancelFunc

	lifecyclePhase      lifecyclePhase
	lifecycleGeneration uint64
	lifecycleCancel     context.CancelFunc
	lifecycleLoading    bool
	lifecycleErr        error
	lifecycleStatus     string
	lifecyclePreview    string
	lifecycleTarget     uint64
	lifecycleCursor     int
	generations         []generation
	clean               cleanPreview
	cleanDraft          cleanPolicyDraft

	doctorReports    [3]doctorReport
	doctorErrors     [3]error
	doctorLoading    [3]bool
	doctorRequested  [3]bool
	doctorTab        doctorTab
	doctorCursor     int
	doctorGeneration uint64
	doctorCancel     context.CancelFunc

	inventoryDiagnostic  string
	inventoryDetailsOpen bool
	details              bool
	capabilitiesOpen     bool
	focus                pane
	previewCursor        int
	capabilityCursor     int
	selectedCapability   int
	width                int
	height               int
	err                  error
	status               string
}

func commandOutput(ctx context.Context, name string, args ...string) ([]byte, error) {
	return execCommandRunner{}.Output(ctx, name, args...)
}

func execApply(cli string, args ...string) tea.Cmd {
	cmd := exec.Command(cli, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return applyDoneMsg{err: err} })
}

func newAskBackend(docs clikit.DocCorpus) clikit.Asker {
	asker := clikit.NewOmpAsker(docs)
	asker.ReplaceSystem = true
	return asker
}

func newModel(cli string) model {
	asker := &groundedAsker{
		cli:       cli,
		grounding: commandGrounding,
		backend:   newAskBackend,
	}
	return model{
		cli:        cli,
		runner:     execCommandRunner{},
		apply:      execApply,
		asker:      asker,
		nav:        newCockpitNav(),
		phase:      ready,
		cleanDraft: defaultCleanPolicyDraft(),
		width:      100,
		height:     30,
	}
}

func (m model) Asker() clikit.Asker { return m.asker }

func (model) BoxTitle() string { return "ASK ATYRODE · read-only" }

func (m model) Init() tea.Cmd { return nil }

func (m model) loadPlan() tea.Cmd {
	runner := m.runner
	cli := m.cli
	return func() tea.Msg {
		out, err := runner.Output(context.Background(), cli, "apply", "--plan", "--json")
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

func (m *model) startPreview() tea.Cmd {
	if m.previewLoading || m.preview.SchemaVersion != 0 || m.inventoryLoading {
		return nil
	}
	m.previewGeneration++
	generation := m.previewGeneration
	revision, plan := m.plan.ResolvedRevision, m.plan
	ctx, cancel := context.WithCancel(context.Background())
	m.previewCancel = cancel
	m.previewLoading, m.previewErr = true, nil
	runner, cli, args := m.runner, m.cli, m.applyArgs(true)
	return func() tea.Msg {
		out, err := runner.Output(ctx, cli, args...)
		if err != nil {
			return previewMsg{revision: revision, generation: generation, err: commandError("preview apply", out, err)}
		}
		var result previewdata.Document
		if err := json.Unmarshal(out, &result); err != nil {
			return previewMsg{revision: revision, generation: generation, err: fmt.Errorf("decode activation preview: %w", err)}
		}
		if result.SchemaVersion != previewdata.SchemaVersion {
			return previewMsg{revision: revision, generation: generation, err: fmt.Errorf("decode activation preview: unsupported schema version %d", result.SchemaVersion)}
		}
		if result.ResolvedRevision != plan.ResolvedRevision || result.Host != plan.Host || result.System != plan.System {
			return previewMsg{revision: revision, generation: generation, err: fmt.Errorf("decode activation preview: plan identity changed")}
		}
		return previewMsg{revision: revision, generation: generation, preview: result}
	}
}
func (m *model) startInventory() tea.Cmd {
	if m.inventoryRequested || m.previewLoading {
		return nil
	}
	m.inventoryRequested, m.inventoryLoading, m.inventoryErr = true, true, nil
	m.inventoryDiagnostic, m.inventoryDetailsOpen = "", false
	m.inventoryGeneration++
	revision, generation := m.plan.ResolvedRevision, m.inventoryGeneration
	plan := m.plan
	ctx, cancel := context.WithCancel(context.Background())
	m.inventoryCancel = cancel
	runner, cli := m.runner, m.cli
	return func() tea.Msg {
		out, err := runner.Output(ctx, cli, "inventory", "--ref", revision, "--json")
		if err != nil {
			return inventoryMsg{
				revision:   revision,
				generation: generation,
				err:        fmt.Errorf("inventory unavailable: %w", err),
				diagnostic: boundedInventoryDiagnostic(out),
			}
		}
		result, err := inventorydata.Parse(out, inventorydata.Expected{
			Revision:           revision,
			System:             plan.System,
			Host:               plan.Host,
			ActiveCapabilities: plan.Capabilities,
		})
		if err != nil {
			return inventoryMsg{revision: revision, generation: generation, err: err}
		}
		return inventoryMsg{revision: revision, generation: generation, inventory: result}
	}
}

func (m *model) cancelPreview() {
	if m.previewCancel != nil {
		m.previewCancel()
		m.previewCancel = nil
	}
	if m.previewLoading {
		m.previewGeneration++
		m.previewLoading = false
	}
}

func (m *model) cancelInventory() {
	if m.inventoryCancel != nil {
		m.inventoryCancel()
		m.inventoryCancel = nil
	}
	if m.inventoryLoading {
		m.inventoryGeneration++
		m.inventoryLoading = false
	}
}

func (m *model) cancelInspections() {
	m.cancelDoctor()
	m.cancelPreview()
	m.cancelInventory()
	m.cancelLifecycle()
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

const (
	maxInventoryDiagnosticLines = 4
	maxInventoryDiagnosticRunes = 512
)

func boundedInventoryDiagnostic(output []byte) string {
	text := strings.TrimSpace(stripTerminalControls(strings.ReplaceAll(string(output), "\r", "\n")))
	if text == "" {
		return ""
	}
	lines := strings.Split(text, "\n")
	if len(lines) > maxInventoryDiagnosticLines {
		lines = lines[:maxInventoryDiagnosticLines]
		lines[len(lines)-1] = strings.TrimRight(lines[len(lines)-1], " ") + "…"
	}
	text = strings.Join(lines, "\n")
	runes := []rune(text)
	if len(runes) > maxInventoryDiagnosticRunes {
		text = string(runes[:maxInventoryDiagnosticRunes-1]) + "…"
	}
	return text
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
		m.plan, m.phase, m.err = msg.plan, ready, nil
		m.previewGeneration++
		m.preview, m.previewLoading, m.previewErr, m.previewCancel = previewdata.Document{}, false, nil, nil
		m.inventoryGeneration++
		m.inventory, m.inventoryRequested, m.inventoryLoading = inventorydata.Document{}, false, false
		m.inventoryErr, m.inventoryCancel = nil, nil
		m.inventoryDiagnostic, m.inventoryDetailsOpen = "", false
		m.previewCursor, m.capabilityCursor, m.selectedCapability = 0, 0, 0
		m.details, m.capabilitiesOpen, m.focus = false, false, previewPane
		return m, nil
	case previewMsg:
		if msg.generation != m.previewGeneration || msg.revision != m.plan.ResolvedRevision {
			return m, nil
		}
		m.previewLoading, m.previewCancel = false, nil
		if msg.err != nil {
			m.preview, m.previewErr = previewdata.Document{}, msg.err
		} else {
			m.preview, m.previewErr = msg.preview, nil
			m.previewCursor, m.details = 0, false
		}
		return m, nil
	case inventoryMsg:
		if msg.generation != m.inventoryGeneration || msg.revision != m.plan.ResolvedRevision {
			return m, nil
		}
		m.inventoryLoading, m.inventoryCancel = false, nil
		m.inventoryDiagnostic, m.inventoryDetailsOpen = msg.diagnostic, false
		if msg.err != nil {
			m.inventory, m.inventoryErr = inventorydata.Document{}, msg.err
		} else {
			m.inventory, m.inventoryErr = msg.inventory, nil
			if m.selectedCapability >= len(m.inventory.Capabilities) {
				m.selectedCapability = 0
				m.capabilityCursor = 0
			}
		}
		return m, nil
	case doctorMsg:
		if msg.generation != m.doctorGeneration {
			return m, nil
		}
		m.doctorLoading[msg.tab] = false
		if msg.report.err != nil {
			m.doctorReports[msg.tab], m.doctorErrors[msg.tab] = doctorReport{}, msg.report.err
		} else {
			m.doctorReports[msg.tab], m.doctorErrors[msg.tab] = msg.report, nil
			m.doctorCursor = 0
		}
		return m, nil
	case lifecycleMsg:
		return m, m.handleLifecycleMsg(msg)
	case applyDoneMsg:
		if msg.err != nil {
			m.phase, m.err = failed, fmt.Errorf("apply failed: %w", msg.err)
		} else {
			m.phase, m.err, m.status = applied, nil, "Activation completed successfully."
		}
		return m, nil
	case tea.KeyMsg:
		key := msg.String()
		if m.nav.Active() == workspaceLifecycle && m.lifecyclePhase == lifecycleCleanConfiguring && key != "q" && key != "ctrl+c" {
			return m, m.lifecycleUpdate(key)
		}
		if m.lifecyclePhase == lifecycleMutating {
			switch key {
			case "ctrl+c", "q", "tab", "shift+tab":
				return m, nil
			}
			if _, ok := workspaceForShortcut(key); ok {
				return m, nil
			}
		}
		switch key {
		case "ctrl+c", "q":
			m.cancelInspections()
			return m, tea.Quit
		case "tab":
			return m, m.nextWorkspace(1)
		case "shift+tab":
			return m, m.nextWorkspace(-1)
		}
		if id, ok := workspaceForShortcut(key); ok {
			return m, m.activateWorkspace(id)
		}
		if m.nav.Active() == workspaceDoctor {
			return m, m.doctorUpdate(key)
		}
		if m.nav.Active() == workspaceCapability {
			return m, m.capabilitiesWorkspaceUpdate(key)
		}
		if m.nav.Active() == workspaceLifecycle {
			return m, m.lifecycleUpdate(key)
		}
		if m.nav.Active() != workspaceApply {
			return m, nil
		}
		switch key {
		case "r":
			if m.phase != applying {
				m.cancelInspections()
				m.phase, m.err, m.status, m.preview, m.inventory = loadingPlan, nil, "", previewdata.Document{}, inventorydata.Document{}
				m.previewGeneration++
				m.inventoryGeneration++
				m.previewErr, m.previewLoading, m.details = nil, false, false
				m.inventoryErr, m.inventoryRequested, m.inventoryLoading = nil, false, false
				m.inventoryDiagnostic, m.inventoryDetailsOpen = "", false
				m.capabilitiesOpen, m.focus = false, previewPane
				m.previewCursor, m.capabilityCursor, m.selectedCapability = 0, 0, 0
				return m, m.loadPlan()
			}
		case "v":
			if m.previewLoading {
				m.cancelPreview()
				return m, nil
			}
			if (m.phase == ready || m.phase == applied) && m.preview.SchemaVersion == 0 && !m.inventoryLoading {
				return m, m.startPreview()
			}
		case "c":
			if m.phase == ready || m.phase == confirming || m.phase == applied {
				if m.focus == capabilityPane {
					m.focus = previewPane
					if !m.isWide() {
						m.capabilitiesOpen = false
					}
				} else {
					m.focus, m.capabilitiesOpen = capabilityPane, true
					return m, m.startInventory()
				}
			}
		case "[", "left":
			if m.focus == capabilityPane {
				m = m.cycleCapability(-1)
			}
		case "]", "right":
			if m.focus == capabilityPane {
				m = m.cycleCapability(1)
			}
		case "up", "k":
			m = m.scrollFocused(-1)
		case "down", "j":
			m = m.scrollFocused(1)
		case "pgup":
			m = m.scrollFocused(-m.paneBodyHeight())
		case "pgdown":
			m = m.scrollFocused(m.paneBodyHeight())
		case "d":
			if m.focus == capabilityPane && m.inventoryErr != nil && m.inventoryDiagnostic != "" &&
				(m.phase == ready || m.phase == confirming || m.phase == applied) {
				m.inventoryDetailsOpen = !m.inventoryDetailsOpen
				m.capabilityCursor = 0
			} else if m.focus == previewPane && m.preview.SchemaVersion != 0 &&
				(m.phase == ready || m.phase == confirming || m.phase == applied) {
				m.details, m.previewCursor = !m.details, 0
			}
		case "a", "enter":
			if m.phase == ready {
				m.cancelPreview()
				m.phase = confirming
			}
		case "y":
			if m.phase == confirming {
				m.cancelInspections()
				m.phase, m.err = applying, nil
				return m, m.apply(m.cli, m.applyArgs(false)...)
			}
		case "n":
			if m.phase == confirming {
				m.phase = ready
			}
		case "esc":
			if m.phase == confirming {
				m.phase = ready
			} else if m.focus == capabilityPane {
				m.focus = previewPane
				if !m.isWide() {
					m.capabilitiesOpen = false
				}
			}
		}
	}
	return m, nil
}

func (m model) cycleCapability(delta int) model {
	count := len(m.inventory.Capabilities)
	if count == 0 {
		return m
	}
	m.selectedCapability = (m.selectedCapability + delta + count) % count
	m.capabilityCursor = 0
	return m
}

func (m model) scrollFocused(delta int) model {
	if m.focus == capabilityPane {
		m.capabilityCursor = clampCursor(m.capabilityCursor+delta, len(m.capabilityRows()))
	} else {
		m.previewCursor = clampCursor(m.previewCursor+delta, len(m.previewRows()))
	}
	return m
}

func clampCursor(cursor, rows int) int {
	if cursor < 0 || rows == 0 {
		return 0
	}
	if cursor >= rows {
		return rows - 1
	}
	return cursor
}

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(clikit.CHead))
	labelStyle = lipgloss.NewStyle().Foreground(lipgloss.Color(clikit.CDim)).Width(14)
	chipStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color(clikit.CHead)).Background(lipgloss.Color(clikit.CSelBg)).Padding(0, 1)
	iconStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color(clikit.CAcc))
)

func (m model) View() string {
	margin, panelWidth := m.horizontalLayout()
	var content string
	switch m.nav.Active() {
	case workspaceApply:
		content = m.applyView(panelWidth)
	case workspaceLifecycle:
		content = m.lifecycleView(panelWidth)
	case workspaceAsk:
		content = m.askWorkspaceView(panelWidth)
	case workspaceDoctor:
		content = m.doctorView(panelWidth)
	case workspaceCapability:
		content = m.capabilitiesWorkspaceView(panelWidth)
	default:
		content = m.overviewView(panelWidth)
	}
	sections := []string{
		titleStyle.Render("ATYRODE"),
		m.workspaceTabs(panelWidth),
		content,
		m.shellFooter(),
	}
	return clikit.PadLeft(strings.Join(sections, "\n\n"), margin)
}

func (m model) applyView(panelWidth int) string {
	content := m.previewBox(panelWidth)
	if m.isWide() {
		previewWidth, capabilityWidth := m.splitWidths(panelWidth)
		content = lipgloss.JoinHorizontal(lipgloss.Top, m.previewBox(previewWidth), " ", m.capabilityBox(capabilityWidth))
	} else if m.capabilitiesOpen {
		content = m.capabilityBox(panelWidth)
	}
	return strings.Join([]string{m.header(panelWidth), content, m.footer()}, "\n\n")
}

func (m model) isWide() bool { return m.width >= 112 }

func (m model) splitWidths(total int) (previewWidth, capabilityWidth int) {
	capabilityWidth = 42
	if total < 84 {
		capabilityWidth = max(38, total/2)
	}
	previewWidth = max(1, total-capabilityWidth-1)
	return previewWidth, capabilityWidth
}

func (m model) contentPanelWidth() int {
	_, total := m.horizontalLayout()
	if m.isWide() {
		previewWidth, capabilityWidth := m.splitWidths(total)
		if m.focus == capabilityPane {
			return capabilityWidth
		}
		return previewWidth
	}
	return total
}

func (m model) contentOuterHeight() int {
	_, width := m.horizontalLayout()
	fixed := 1 + lipgloss.Height(m.header(width)) + lipgloss.Height(m.footer()) + lipgloss.Height(m.shellFooter()) + 11
	return max(4, m.height-fixed)
}

func (m model) paneBodyHeight() int {
	return max(1, m.contentOuterHeight()-3)
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
			return clikit.Panel(width, clikit.StBrk.Render("Unable to load apply plan"))
		}
		return clikit.Panel(width, clikit.StDim.Render("Resolving host and apply plan…"))
	}

	dirty := clikit.StOk.Render("clean")
	if m.plan.Dirty {
		dirty = clikit.StWarn.Render("dirty")
	}
	available := clikit.PanelContentWidth(width)
	targetWidth := available - lipgloss.Width(labelStyle.Render("target")) - 2
	if targetWidth < 1 {
		targetWidth = 1
	}
	target := ansi.Truncate(m.plan.Installable, targetWidth, "…")
	compactTarget := ansi.Truncate(m.plan.Installable, available-2, "…")
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
	return clikit.Panel(width, strings.Join(lines, "\n"))
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
	return m.paneBodyHeight()
}

func (m model) previewBox(width int) string {
	previewWidth := max(1, clikit.PanelContentWidth(width)-4)
	var body string
	if m.preview.SchemaVersion != 0 {
		body = clikit.WindowList(m.previewRowsForWidth(max(1, previewWidth-1)), m.previewCursor, m.previewHeight(), previewWidth)
	} else {
		body = clikit.WindowList(m.previewStatusRows(max(1, previewWidth-1)), 0, m.previewHeight(), previewWidth)
	}
	label := iconStyle.Render("\uf0ad") + "  " + titleStyle.Render("ACTIVATION PREVIEW")
	if m.focus == previewPane {
		label += clikit.StHead.Render("  ·  FOCUSED")
	}
	return clikit.Panel(width, label+"\n"+body)
}

func (m model) previewStatusRows(width int) []string {
	rows := make([]string, 0, 10)
	switch {
	case m.phase == loadingPlan:
		appendWrappedRow(&rows, clikit.StDim.Render("Loading apply plan…"), width)
	case m.phase == applying:
		appendWrappedRow(&rows, clikit.StWarn.Render("Apply is running in the terminal…"), width)
	case m.previewLoading:
		appendWrappedRow(&rows, titleStyle.Render("Loading optional dry preview…"), width)
		rows = append(rows, "")
		appendWrappedRow(&rows, clikit.StDim.Render("The exact-revision Nix evaluation is running in the background."), width)
		appendWrappedRow(&rows, "Apply controls remain available. Press v to cancel.", width)
	case m.previewErr != nil:
		appendWrappedRow(&rows, clikit.StBrk.Bold(true).Render("Preview unavailable"), width)
		rows = append(rows, "")
		reason := strings.Split(stripTerminalControls(m.previewErr.Error()), "\n")
		if len(reason) > maxErrorLines {
			reason = reason[:maxErrorLines]
		}
		for _, line := range reason {
			appendWrappedRow(&rows, clikit.StDim.Render(line), width)
		}
		rows = append(rows, "")
		appendWrappedRow(&rows, "Press v to retry. Apply remains available.", width)
	default:
		marker := "Preview not loaded"
		if m.phase == confirming {
			marker = "Optional dry preview was not run."
		}
		appendWrappedRow(&rows, titleStyle.Render(marker), width)
		rows = append(rows, "")
		appendWrappedRow(&rows, clikit.StDim.Render("The validated exact-revision plan is ready."), width)
		if m.phase == confirming {
			appendWrappedRow(&rows, "Apply can continue without the optional package/action diff.", width)
		} else if m.inventoryLoading {
			appendWrappedRow(&rows, "Capability inventory is loading. Preview waits to avoid duplicate Nix evaluation.", width)
		} else {
			appendWrappedRow(&rows, "Press v to load the optional package/action diff.", width)
		}
	}
	return rows
}
func (m model) capabilityPanelWidth() int {
	_, total := m.horizontalLayout()
	if m.isWide() {
		_, width := m.splitWidths(total)
		return width
	}
	return total
}

func (m model) capabilityBox(width int) string {
	bodyWidth := max(1, clikit.PanelContentWidth(width)-4)
	rows := m.capabilityRowsForWidth(max(1, bodyWidth-1))
	body := clikit.WindowList(rows, m.capabilityCursor, m.paneBodyHeight(), bodyWidth)
	label := iconStyle.Render("\uf085") + "  " + titleStyle.Render("CAPABILITIES")
	if m.focus == capabilityPane {
		label += clikit.StHead.Render("  ·  FOCUSED")
	}
	return clikit.Panel(width, label+"\n"+body)
}

func (m model) capabilityRows() []string {
	width := max(1, clikit.PanelContentWidth(m.capabilityPanelWidth())-5)
	return m.capabilityRowsForWidth(width)
}

func (m model) capabilityRowsForWidth(width int) []string {
	rows := make([]string, 0, 32)
	switch {
	case !m.inventoryRequested:
		appendWrappedRow(&rows, titleStyle.Render("Inventory not loaded"), width)
		rows = append(rows, "")
		if m.previewLoading {
			appendWrappedRow(&rows, clikit.StDim.Render("Cancel the running preview with v before loading capabilities."), width)
		} else {
			appendWrappedRow(&rows, clikit.StDim.Render("Press c to load exact-revision capability details."), width)
		}
		return rows
	case m.inventoryLoading:
		appendWrappedRow(&rows, clikit.StDim.Render("Loading exact-revision inventory…"), width)
		return rows
	case m.inventoryErr != nil:
		appendWrappedRow(&rows, clikit.StBrk.Bold(true).Render("Inventory unavailable"), width)
		rows = append(rows, "")
		reason := strings.TrimPrefix(m.inventoryErr.Error(), "inventory unavailable: ")
		appendWrappedRow(&rows, clikit.StDim.Render(stripTerminalControls(reason)), width)
		if m.inventoryDiagnostic != "" {
			rows = append(rows, "")
			if m.inventoryDetailsOpen {
				appendWrappedRow(&rows, titleStyle.Render("Diagnostic detail"), width)
				for _, line := range strings.Split(m.inventoryDiagnostic, "\n") {
					appendIndentedWrappedRow(&rows, clikit.StDim.Render(line), width, 2)
				}
			} else {
				appendWrappedRow(&rows, clikit.StDim.Render("Press d to show bounded diagnostic detail."), width)
			}
		}
		rows = append(rows, "")
		appendWrappedRow(&rows, "The activation preview and apply confirmation remain available.", width)
		return rows
	case len(m.inventory.Capabilities) == 0:
		appendWrappedRow(&rows, clikit.StDim.Render("No active capabilities were declared by this apply plan."), width)
		return rows
	}

	index := m.selectedCapability
	if index < 0 || index >= len(m.inventory.Capabilities) {
		index = 0
	}
	capability := m.inventory.Capabilities[index]
	appendWrappedRow(&rows, titleStyle.Render(capability.Title)+clikit.StDim.Render(fmt.Sprintf("  %d/%d", index+1, len(m.inventory.Capabilities))), width)
	state := "ACTIVE"
	if !capability.Applicable {
		state = "ACTIVE · NOT APPLICABLE ON " + strings.ToUpper(m.inventory.Identity.Platform)
	}
	appendWrappedRow(&rows, clikit.StHead.Render(state)+clikit.StDim.Render(fmt.Sprintf("  ·  %d items", len(capability.Deliverables))), width)
	rows = append(rows, "")
	appendWrappedRow(&rows, capability.Purpose, width)

	if len(capability.Deliverables) == 0 {
		rows = append(rows, "")
		marker := "No direct deliverables."
		if capability.Marker {
			marker = "Intentional marker · no direct deliverables."
		}
		appendWrappedRow(&rows, clikit.StWarn.Render(marker), width)
	} else {
		for _, group := range deliverableGroups(capability.Deliverables) {
			rows = append(rows, "")
			appendWrappedRow(&rows, titleStyle.Render(fmt.Sprintf("%s (%d)", kindTitle(group.kind), len(group.items))), width)
			for _, item := range group.items {
				appendIndentedWrappedRow(&rows, item.Description, width, 2)
				secondary := strings.TrimSpace(strings.Join(nonEmpty(item.Name, item.Version, item.Source), "  ·  "))
				if secondary != "" {
					appendIndentedWrappedRow(&rows, clikit.StDim.Render(secondary), width, 4)
				}
				if item.Delivery != "" {
					appendIndentedWrappedRow(&rows, clikit.StDim.Render("via "+item.Delivery), width, 4)
				}
				if item.System != "" {
					appendIndentedWrappedRow(&rows, clikit.StDim.Render("for "+item.System), width, 4)
				}
			}
		}
	}

	boundaries := []struct {
		label string
		value string
	}{
		{label: "Delivery boundary", value: capability.DeliveryBoundary},
		{label: "Security boundary", value: capability.SecurityBoundary},
		{label: "Mutable state", value: capability.MutableState},
	}
	for _, boundary := range boundaries {
		if boundary.value == "" {
			continue
		}
		rows = append(rows, "")
		appendWrappedRow(&rows, clikit.StHead.Render(boundary.label), width)
		appendIndentedWrappedRow(&rows, clikit.StDim.Render(boundary.value), width, 2)
	}
	return rows
}

type deliverableGroup struct {
	kind  string
	items []inventorydata.Deliverable
}

func deliverableGroups(items []inventorydata.Deliverable) []deliverableGroup {
	groups := make([]deliverableGroup, 0, 2)
	indices := make(map[string]int, 2)
	for _, item := range items {
		index, ok := indices[item.Kind]
		if !ok {
			index = len(groups)
			indices[item.Kind] = index
			groups = append(groups, deliverableGroup{kind: item.Kind})
		}
		groups[index].items = append(groups[index].items, item)
	}
	return groups
}

func kindTitle(kind string) string {
	switch kind {
	case "package":
		return "Packages"
	case "application":
		return "Applications"
	case "":
		return "Deliverables"
	default:
		return strings.ToUpper(kind[:1]) + kind[1:]
	}
}

func nonEmpty(values ...string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		if value != "" {
			result = append(result, value)
		}
	}
	return result
}

func (m model) previewRows() []string {
	_, width := m.horizontalLayout()
	if m.isWide() {
		width, _ = m.splitWidths(width)
	}
	previewWidth := max(1, clikit.PanelContentWidth(width)-4)
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
	lines = append(lines, clikit.StDim.Render("^O ask  ·  r retry  ·  q quit"))
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
	if m.focus == capabilityPane {
		controls := "↑/↓ scroll  ·  [/] cycle  ·  c back"
		if m.isWide() {
			controls = "↑/↓ capability  ·  [/] cycle  ·  c preview"
		}
		if m.inventoryErr != nil && m.inventoryDiagnostic != "" && m.width >= 80 {
			diagnosticMode := "diagnostics"
			if m.inventoryDetailsOpen {
				diagnosticMode = "hide diagnostics"
			}
			controls += "  ·  d " + diagnosticMode
		}
		if m.width < 60 {
			if m.phase == confirming {
				return clikit.StWarn.Render("c back  ·  y/n apply")
			}
			return clikit.StDim.Render("c back  ·  a apply  ·  q")
		}
		if m.phase == confirming {
			controls += "  ·  y confirm  ·  n cancel"
			return clikit.StWarn.Render(controls)
		}
		return clikit.StDim.Render(controls + "  ·  enter apply  ·  q")
	}
	switch m.phase {
	case confirming:
		if m.width < 80 {
			return clikit.StWarn.Render("Apply plan?  y confirm  ·  n cancel")
		}
		return clikit.StWarn.Render("Apply this configuration?  y confirm  ·  n cancel  ·  c capabilities  ·  ^O ask")
	case applying:
		return clikit.StDim.Render("Applying…  ·  ^O ask")
	case applied:
		if m.width < 60 {
			return clikit.StOk.Render(m.status) + "\n" + clikit.StDim.Render("c caps  ·  r refresh  ·  q")
		}
		return clikit.StOk.Render(m.status) + "\n" + clikit.StDim.Render("c capabilities  ·  r refresh  ·  ^O ask  ·  q quit")
	case ready:
		previewControl := "v preview"
		if m.previewLoading {
			previewControl = "v cancel preview"
		} else if m.preview.SchemaVersion != 0 {
			previewControl = "d " + mode
		}
		if m.width < 60 {
			if m.previewLoading {
				return clikit.StDim.Render("v cancel  ·  a apply  ·  q")
			}
			return clikit.StDim.Render(previewControl + "  ·  c caps  ·  a apply  ·  q")
		}
		if m.width < 112 {
			mediumControl := previewControl
			if m.previewLoading {
				mediumControl = "v cancel"
			}
			return clikit.StDim.Render("↑/↓ scroll  ·  " + mediumControl + "  ·  c capabilities  ·  enter apply  ·  q")
		}
		return clikit.StDim.Render("↑/↓ preview  ·  " + previewControl + "  ·  c capabilities  ·  enter apply  ·  r refresh  ·  ^O ask  ·  q")
	default:
		return clikit.StDim.Render("^O ask  ·  q quit")
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
