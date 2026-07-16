package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"

	clikit "github.com/atyrode/cli-kit"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

type lifecyclePhase int

const (
	lifecycleBrowsing lifecyclePhase = iota
	lifecycleCleanConfiguring
	lifecycleRollbackPreviewing
	lifecycleRollbackConfirming
	lifecycleCleanPreviewing
	lifecycleCleanConfirming
	lifecycleMutating
	lifecycleSucceeded
	lifecycleFailed
)

type generation struct {
	Generation  uint64 `json:"generation"`
	Date        string `json:"date"`
	Current     bool   `json:"current"`
	ClosureSize string `json:"closureSize,omitempty"`
}

type cleanCandidate struct {
	Generation  uint64 `json:"generation"`
	Date        string `json:"date"`
	ClosureSize string `json:"closureSize,omitempty"`
}

type cleanPreview struct {
	Scope       string `json:"scope"`
	Platform    string `json:"platform"`
	Profile     string `json:"profile"`
	Keep        int    `json:"keep"`
	KeepSince   string `json:"keepSince"`
	DryRun      bool   `json:"dryRun"`
	Generations struct {
		Total      int `json:"total"`
		Candidates int `json:"candidates"`
	} `json:"generations"`
	ReclaimCandidates []cleanCandidate `json:"reclaimCandidates"`
	Note              string           `json:"note"`
}

type cleanPolicyField int

const (
	cleanKeepField cleanPolicyField = iota
	cleanKeepSinceField
	cleanScopeField
	cleanVerboseField
	cleanPolicyFieldCount
)

type cleanPolicyDraft struct {
	Keep      string
	KeepSince string
	All       bool
	Verbose   bool
	Field     cleanPolicyField
	Err       string
}

func defaultCleanPolicyDraft() cleanPolicyDraft {
	return cleanPolicyDraft{Keep: "5", KeepSince: "30d"}
}

type lifecycleAction int

const (
	loadGenerations lifecycleAction = iota
	previewRollback
	previewClean
	executeRollback
	executeClean
)

type lifecycleMsg struct {
	generation  uint64
	action      lifecycleAction
	generations []generation
	clean       cleanPreview
	output      string
	err         error
}

func decodeLifecycleJSON[T any](out []byte, target *T) error {
	decoder := json.NewDecoder(bytes.NewReader(out))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("unexpected trailing JSON value")
		}
		return err
	}
	return nil
}

func validateGenerations(generations []generation) error {
	seen := make(map[uint64]struct{}, len(generations))
	current := 0
	for _, generation := range generations {
		if generation.Generation == 0 || strings.TrimSpace(generation.Date) == "" {
			return fmt.Errorf("generation records require a positive generation and date")
		}
		if _, ok := seen[generation.Generation]; ok {
			return fmt.Errorf("duplicate generation %d", generation.Generation)
		}
		seen[generation.Generation] = struct{}{}
		if generation.Current {
			current++
		}
	}
	if current > 1 {
		return fmt.Errorf("more than one generation is current")
	}
	return nil
}

func validateCleanPreview(preview cleanPreview) error {
	if preview.Keep < 0 || strings.TrimSpace(preview.KeepSince) == "" || !preview.DryRun ||
		(preview.Scope != "user" && preview.Scope != "all") || strings.TrimSpace(preview.Profile) == "" {
		return fmt.Errorf("clean preview has invalid retention policy")
	}
	seen := make(map[uint64]struct{}, len(preview.ReclaimCandidates))
	for _, candidate := range preview.ReclaimCandidates {
		if candidate.Generation == 0 || strings.TrimSpace(candidate.Date) == "" {
			return fmt.Errorf("clean candidate requires a positive generation and date")
		}
		if _, ok := seen[candidate.Generation]; ok {
			return fmt.Errorf("duplicate clean candidate %d", candidate.Generation)
		}
		seen[candidate.Generation] = struct{}{}
	}
	return nil
}

func (m *model) loadLifecycle() tea.Cmd {
	m.cancelLifecycle()
	m.lifecycleGeneration++
	requestGeneration := m.lifecycleGeneration
	ctx, cancel := context.WithCancel(context.Background())
	m.lifecycleCancel = cancel
	m.lifecycleLoading, m.lifecycleErr = true, nil
	runner, cli := m.runner, m.cli
	return func() tea.Msg {
		out, err := runner.Output(ctx, cli, "generations", "--json", "--sizes")
		if err != nil {
			return lifecycleMsg{generation: requestGeneration, action: loadGenerations, err: commandError("load generations", out, err)}
		}
		var generations []generation
		if err := decodeLifecycleJSON(out, &generations); err != nil {
			return lifecycleMsg{generation: requestGeneration, action: loadGenerations, err: fmt.Errorf("decode generations: %w", err)}
		}
		if err := validateGenerations(generations); err != nil {
			return lifecycleMsg{generation: requestGeneration, action: loadGenerations, err: fmt.Errorf("decode generations: %w", err)}
		}
		return lifecycleMsg{generation: requestGeneration, action: loadGenerations, generations: generations}
	}
}

func (m *model) lifecycleCommand(action lifecycleAction, args ...string) tea.Cmd {
	m.cancelLifecycle()
	m.lifecycleGeneration++
	generation := m.lifecycleGeneration
	ctx, cancel := context.WithCancel(context.Background())
	m.lifecycleCancel = cancel
	m.lifecycleErr = nil
	runner, cli := m.runner, m.cli
	cleanDraft := m.cleanDraft
	return func() tea.Msg {
		out, err := runner.Output(ctx, cli, args...)
		if err != nil {
			return lifecycleMsg{generation: generation, action: action, err: commandError("lifecycle command", out, err)}
		}
		if action == previewClean {
			var preview cleanPreview
			if err := decodeLifecycleJSON(out, &preview); err != nil {
				return lifecycleMsg{generation: generation, action: action, err: fmt.Errorf("decode clean preview: %w", err)}
			}
			if err := validateCleanPreview(preview); err != nil {
				return lifecycleMsg{generation: generation, action: action, err: fmt.Errorf("decode clean preview: %w", err)}
			}
			expectedKeep, parseErr := strconv.Atoi(cleanDraft.Keep)
			expectedScope := "user"
			if cleanDraft.All {
				expectedScope = "all"
			}
			if parseErr != nil || preview.Keep != expectedKeep || preview.KeepSince != cleanDraft.KeepSince || preview.Scope != expectedScope {
				return lifecycleMsg{generation: generation, action: action, err: fmt.Errorf("clean preview does not match the requested retention policy")}
			}
			return lifecycleMsg{generation: generation, action: action, clean: preview}
		}
		return lifecycleMsg{generation: generation, action: action, output: boundedLifecycleOutput(out)}
	}
}

func (m *model) cancelLifecycle() {
	if m.lifecycleCancel != nil {
		m.lifecycleCancel()
		m.lifecycleCancel = nil
	}
	m.lifecycleLoading = false
}

func (m model) selectedGeneration() (generation, bool) {
	if m.lifecycleCursor < 0 || m.lifecycleCursor >= len(m.generations) {
		return generation{}, false
	}
	return m.generations[m.lifecycleCursor], true
}

func (d cleanPolicyDraft) values() (int, string, error) {
	keep, err := strconv.Atoi(d.Keep)
	if err != nil || keep < 0 {
		return 0, "", fmt.Errorf("keep newest must be a non-negative number")
	}
	keepSince := strings.TrimSpace(d.KeepSince)
	if keepSince == "" {
		return 0, "", fmt.Errorf("keep since must not be empty")
	}
	return keep, keepSince, nil
}

func cleanCommandArgs(keep int, keepSince string, all, verbose, preview bool) []string {
	args := []string{"clean", "--keep", strconv.Itoa(keep), "--keep-since", keepSince}
	if all {
		args = append(args, "--all")
	}
	if verbose {
		args = append(args, "--verbose")
	}
	if preview {
		return append(args, "--dry-run", "--json")
	}
	return append(args, "--yes")
}

func trimLastRune(value string) string {
	runes := []rune(value)
	if len(runes) == 0 {
		return value
	}
	return string(runes[:len(runes)-1])
}

func (m *model) cleanPolicyUpdate(key string) tea.Cmd {
	switch key {
	case "esc":
		m.cleanDraft.Err = ""
		m.lifecyclePhase = lifecycleBrowsing
	case "tab", "down":
		m.cleanDraft.Field = cleanPolicyField((int(m.cleanDraft.Field) + 1) % int(cleanPolicyFieldCount))
	case "shift+tab", "up":
		m.cleanDraft.Field = cleanPolicyField((int(m.cleanDraft.Field) + int(cleanPolicyFieldCount) - 1) % int(cleanPolicyFieldCount))
	case "ctrl+x":
		m.cleanDraft.Keep, m.cleanDraft.KeepSince, m.cleanDraft.Err = "0", "0d", ""
	case "left", "right", "space":
		switch m.cleanDraft.Field {
		case cleanScopeField:
			m.cleanDraft.All = !m.cleanDraft.All
		case cleanVerboseField:
			m.cleanDraft.Verbose = !m.cleanDraft.Verbose
		}
	case "backspace", "delete":
		switch m.cleanDraft.Field {
		case cleanKeepField:
			m.cleanDraft.Keep = trimLastRune(m.cleanDraft.Keep)
		case cleanKeepSinceField:
			m.cleanDraft.KeepSince = trimLastRune(m.cleanDraft.KeepSince)
		}
	case "enter":
		keep, keepSince, err := m.cleanDraft.values()
		if err != nil {
			m.cleanDraft.Err = err.Error()
			return nil
		}
		m.cleanDraft.Keep, m.cleanDraft.KeepSince, m.cleanDraft.Err = strconv.Itoa(keep), keepSince, ""
		m.lifecyclePhase = lifecycleCleanPreviewing
		return m.lifecycleCommand(previewClean, cleanCommandArgs(keep, keepSince, m.cleanDraft.All, m.cleanDraft.Verbose, true)...)
	default:
		runes := []rune(key)
		if len(runes) != 1 || len(key) > 4 {
			return nil
		}
		switch m.cleanDraft.Field {
		case cleanKeepField:
			if runes[0] >= '0' && runes[0] <= '9' && len(m.cleanDraft.Keep) < 6 {
				m.cleanDraft.Keep += key
			}
		case cleanKeepSinceField:
			if !strings.ContainsAny(key, " \t\r\n") && len(m.cleanDraft.KeepSince) < 32 {
				m.cleanDraft.KeepSince += key
			}
		}
	}
	return nil
}

func (m *model) lifecycleUpdate(key string) tea.Cmd {
	if m.lifecyclePhase == lifecycleCleanConfiguring {
		return m.cleanPolicyUpdate(key)
	}
	switch key {
	case "r":
		if m.lifecyclePhase == lifecycleBrowsing || m.lifecyclePhase == lifecycleSucceeded || m.lifecyclePhase == lifecycleFailed {
			selected, ok := m.selectedGeneration()
			if ok && !selected.Current {
				m.lifecyclePhase, m.lifecycleTarget = lifecycleRollbackPreviewing, selected.Generation
				return m.lifecycleCommand(previewRollback, "rollback", "--to", strconv.FormatUint(selected.Generation, 10), "--dry-run")
			}
		}
	case "c":
		if m.lifecyclePhase == lifecycleBrowsing || m.lifecyclePhase == lifecycleSucceeded || m.lifecyclePhase == lifecycleFailed {
			m.cleanDraft.Err = ""
			m.lifecycleErr = nil
			m.lifecyclePhase = lifecycleCleanConfiguring
		}
	case "y":
		switch m.lifecyclePhase {
		case lifecycleRollbackConfirming:
			m.lifecyclePhase = lifecycleMutating
			return m.lifecycleCommand(executeRollback, "rollback", "--to", strconv.FormatUint(m.lifecycleTarget, 10), "--yes")
		case lifecycleCleanConfirming:
			m.lifecyclePhase = lifecycleMutating
			return m.lifecycleCommand(executeClean, cleanCommandArgs(m.clean.Keep, m.clean.KeepSince, m.clean.Scope == "all", m.cleanDraft.Verbose, false)...)
		}
	case "n", "esc":
		switch m.lifecyclePhase {
		case lifecycleRollbackConfirming, lifecycleCleanConfirming:
			m.lifecyclePhase = lifecycleBrowsing
			m.lifecycleStatus = "Cancelled — nothing changed."
		case lifecycleRollbackPreviewing, lifecycleCleanPreviewing:
			m.cancelLifecycle()
			m.lifecycleGeneration++
			m.lifecyclePhase, m.lifecycleStatus = lifecycleBrowsing, "Cancelled — nothing changed."
		}
	case "up", "k":
		if m.lifecyclePhase == lifecycleBrowsing {
			m.lifecycleCursor = clampCursor(m.lifecycleCursor-1, len(m.generations))
		}
	case "down", "j":
		if m.lifecyclePhase == lifecycleBrowsing {
			m.lifecycleCursor = clampCursor(m.lifecycleCursor+1, len(m.generations))
		}
	case "pgup":
		if m.lifecyclePhase == lifecycleBrowsing {
			m.lifecycleCursor = clampCursor(m.lifecycleCursor-m.paneBodyHeight(), len(m.generations))
		}
	case "pgdown":
		if m.lifecyclePhase == lifecycleBrowsing {
			m.lifecycleCursor = clampCursor(m.lifecycleCursor+m.paneBodyHeight(), len(m.generations))
		}
	case "refresh", "ctrl+r":
		if m.lifecyclePhase != lifecycleMutating {
			m.lifecyclePhase, m.lifecycleStatus = lifecycleBrowsing, ""
			return m.loadLifecycle()
		}
	}
	return nil
}

func (m *model) handleLifecycleMsg(msg lifecycleMsg) tea.Cmd {
	if msg.generation != m.lifecycleGeneration {
		return nil
	}
	m.lifecycleCancel, m.lifecycleLoading = nil, false
	if msg.err != nil && msg.action == loadGenerations && m.lifecyclePhase == lifecycleSucceeded {
		m.lifecycleStatus += " Refresh failed: " + msg.err.Error()
		return nil
	}
	if msg.err != nil {
		m.lifecycleErr, m.lifecyclePhase = msg.err, lifecycleFailed
		return nil
	}
	switch msg.action {
	case loadGenerations:
		m.generations, m.lifecycleCursor, m.lifecyclePhase = msg.generations, 0, lifecycleBrowsing
	case previewRollback:
		m.lifecyclePreview, m.lifecyclePhase = msg.output, lifecycleRollbackConfirming
	case previewClean:
		m.clean, m.lifecyclePhase = msg.clean, lifecycleCleanConfirming
	case executeRollback:
		m.lifecyclePreview, m.lifecycleStatus, m.lifecyclePhase = msg.output, fmt.Sprintf("Rolled back to generation %d.", m.lifecycleTarget), lifecycleSucceeded
		return m.loadLifecycle()
	case executeClean:
		m.lifecyclePreview, m.lifecycleStatus, m.lifecyclePhase = msg.output, "Clean completed successfully.", lifecycleSucceeded
		return m.loadLifecycle()
	}
	return nil
}

func boundedLifecycleOutput(out []byte) string {
	text := strings.TrimSpace(stripTerminalControls(string(out)))
	if text == "" {
		return "Command completed."
	}
	lines := strings.Split(text, "\n")
	if len(lines) > maxErrorLines {
		lines = lines[:maxErrorLines]
	}
	return strings.Join(lines, "\n")
}

func (m model) lifecycleView(width int) string {
	bodyWidth := max(1, clikit.PanelContentWidth(width)-1)
	rows := m.lifecycleRowsForWidth(max(1, bodyWidth-1))
	bodyHeight := min(max(1, len(rows)), m.workspaceBodyHeight())
	rowCursor := 0
	if m.lifecyclePhase == lifecycleBrowsing {
		rowCursor = m.lifecycleCursor
		if m.lifecycleStatus != "" {
			rowCursor += 2
		}
	} else if m.lifecyclePhase == lifecycleCleanConfiguring {
		rowCursor = 1 + int(m.cleanDraft.Field)
	}
	body := clikit.WindowList(rows, rowCursor, bodyHeight, bodyWidth)
	panel := clikit.Panel(width, titleStyle.Render("Generations / Clean")+"\n\n"+body)
	return strings.Join([]string{panel, m.lifecycleFooter(width)}, "\n\n")
}

func (m model) lifecycleRowsForWidth(width int) []string {
	if m.lifecycleLoading {
		return []string{clikit.StDim.Render("Loading lifecycle data…")}
	}
	if m.lifecycleErr != nil {
		return []string{clikit.StBrk.Render("Lifecycle command failed"), clikit.StDim.Render(ansi.Truncate(m.lifecycleErr.Error(), width, "…"))}
	}
	switch m.lifecyclePhase {
	case lifecycleCleanConfiguring:
		scope := "user profile"
		if m.cleanDraft.All {
			scope = "all profiles (--all)"
		}
		verbose := "off"
		if m.cleanDraft.Verbose {
			verbose = "on"
		}
		values := []string{
			"Keep newest: " + m.cleanDraft.Keep,
			"Keep since: " + m.cleanDraft.KeepSince,
			"Scope: " + scope,
			"Verbose plan: " + verbose,
		}
		rows := []string{titleStyle.Render("Configure cleanup")}
		for field, value := range values {
			marker := "  "
			if cleanPolicyField(field) == m.cleanDraft.Field {
				marker = "> "
			}
			rows = append(rows, marker+value)
		}
		rows = append(rows, "",
			clikit.StDim.Render("Ctrl+X selects maximum reclaim (keep 0, since 0d)."),
			clikit.StDim.Render("The current generation is always retained."),
		)
		if m.cleanDraft.Err != "" {
			rows = append(rows, clikit.StBrk.Render(m.cleanDraft.Err))
		}
		return rows
	case lifecycleRollbackPreviewing:
		return []string{clikit.StDim.Render("Previewing rollback…")}
	case lifecycleRollbackConfirming:
		return []string{clikit.StWarn.Render(fmt.Sprintf("Preview: rollback to generation %d", m.lifecycleTarget)), m.lifecyclePreview, "", clikit.StHead.Render("Confirm rollback? y / n")}
	case lifecycleCleanPreviewing:
		return []string{clikit.StDim.Render("Loading cleanup preview…")}
	case lifecycleCleanConfirming:
		rows := []string{
			clikit.StWarn.Render("Cleanup preview"),
			fmt.Sprintf("Keep newest: %d", m.clean.Keep),
			"Keep since: " + m.clean.KeepSince,
			"Scope: " + m.clean.Scope,
			fmt.Sprintf("Verbose plan: %t", m.cleanDraft.Verbose),
			clikit.StDim.Render("Current generation is always retained."),
		}
		for _, candidate := range m.clean.ReclaimCandidates {
			line := fmt.Sprintf("  %d  %s", candidate.Generation, candidate.Date)
			if candidate.ClosureSize != "" {
				line += "  " + candidate.ClosureSize
			}
			rows = append(rows, ansi.Truncate(line, width, "…"))
		}
		return append(rows, "", clikit.StHead.Render("Confirm clean? y / n"))
	case lifecycleMutating:
		return []string{clikit.StDim.Render("Applying confirmed lifecycle action…")}
	}
	rows := make([]string, 0, len(m.generations)+2)
	if m.lifecycleStatus != "" {
		rows = append(rows, clikit.StOk.Render(m.lifecycleStatus), "")
	}
	for index, generation := range m.generations {
		marker := " "
		if index == m.lifecycleCursor {
			marker = ">"
		}
		state := ""
		if generation.Current {
			state = "  current"
		}
		line := fmt.Sprintf("%s %d  %s%s", marker, generation.Generation, generation.Date, state)
		if generation.ClosureSize != "" {
			line += "  " + generation.ClosureSize
		}
		rows = append(rows, ansi.Truncate(line, width, "…"))
	}
	return rows
}

func (m model) lifecycleFooter(width int) string {
	text := "↑↓ select  ·  r preview rollback  ·  c configure clean  ·  Ctrl+R refresh"
	if width < 60 {
		text = "↑↓ select  ·  r rollback  ·  c clean"
	}
	switch m.lifecyclePhase {
	case lifecycleCleanConfiguring:
		text = "Tab field  ·  type edit  ·  ←/→ toggle  ·  Ctrl+X max  ·  Enter preview  ·  Esc cancel"
		if width < 60 {
			text = "Tab field  ·  ←/→ toggle  ·  Enter preview"
		}
	case lifecycleRollbackConfirming, lifecycleCleanConfirming:
		text = "y confirm  ·  n / Esc cancel"
	}
	return clikit.ClipLines(clikit.StDim.Render(text), width)
}
