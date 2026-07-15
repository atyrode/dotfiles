package main

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	previewdata "atyrode-tui/preview"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const testRevision = "feedfacefeedfacefeedfacefeedfacefeedface"

func testPreviewDocument() previewdata.Document {
	return previewdata.Document{
		SchemaVersion:    previewdata.SchemaVersion,
		Host:             "workstation",
		System:           "x86_64-linux",
		ResolvedRevision: testRevision,
		Status:           "built",
		Packages: previewdata.PackageGroups{
			Added: []previewdata.PackageChange{{Name: "gamma", ChangeKind: "added", NewVersion: "4.0", SizeDelta: "+2.00 MiB"}},
			Updated: []previewdata.PackageChange{
				{Name: "alpha", ChangeKind: "upgraded", PreviousVersion: "1.0", NewVersion: "2.0", SizeDelta: "+9.67 KiB"},
				{Name: "beta", ChangeKind: "downgraded", PreviousVersion: "3.0", NewVersion: "2.5", SizeDelta: "-1.00 MiB"},
			},
			Removed: []previewdata.PackageChange{{Name: "delta", ChangeKind: "removed", PreviousVersion: "5.0", SizeDelta: "-7.00 MiB"}},
		},
		StorePaths:  &previewdata.StorePathSummary{Previous: 7529, Resulting: 7536, Added: 5054, Removed: 5047},
		Closure:     &previewdata.ClosureSummary{Previous: "1.50 GiB", Resulting: "1.49 GiB", Delta: "-5.59 MiB"},
		Generations: &previewdata.GenerationPaths{Previous: "/nix/store/old-home-manager-generation", New: "/nix/store/new-home-manager-generation"},
		Technical:   []string{"<<< /nix/store/old-home-manager-generation", ">>> /nix/store/new-home-manager-generation", "PATHS: 7529 -> 7536 (+5054, -5047)", "SIZE: 1.50 GiB -> 1.49 GiB", "DIFF: -5.59 MiB"},
	}
}

func TestInitLoadsPlanThenDryRunPreview(t *testing.T) {
	var calls [][]string
	m := newModel("/bin/atyrode")
	m.output = func(name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		switch len(calls) {
		case 1:
			return []byte(`{"host":"workstation","system":"x86_64-linux","user":"alex","capabilities":["base","agents"],"installable":"github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface#workstation","revision":"feedfacefeed","resolvedRevision":"feedfacefeedfacefeedfacefeedfacefeedface","source":"remote"}`), nil
		case 2:
			result, err := json.Marshal(testPreviewDocument())
			if err != nil {
				t.Fatal(err)
			}
			return result, nil
		default:
			t.Fatal("unexpected command")
			return nil, nil
		}
	}

	plan := m.Init()().(planMsg)
	next, cmd := m.Update(plan)
	m = next.(model)
	preview := cmd().(previewMsg)
	next, _ = m.Update(preview)
	m = next.(model)

	wantCalls := [][]string{
		{"/bin/atyrode", "apply", "--plan", "--json"},
		{"/bin/atyrode", "apply", "--ref", testRevision, "--preview-json"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("commands = %#v, want %#v", calls, wantCalls)
	}
	if m.phase != ready {
		t.Fatalf("phase = %v, want ready", m.phase)
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{"ACTIVATION PREVIEW", "Applying revision feedfacefeed", "Preview built", "1 added", "2 updated", "1 removed", "Disk usage decreases by 5.59 MiB"} {
		if !strings.Contains(view, want) {
			t.Errorf("visible summary missing %q", want)
		}
	}
	allRows := stripTerminalControls(strings.Join(m.previewRowsForWidth(80), "\n"))
	for _, want := range []string{"Added (1)", "Updated (2)", "Removed (1)", "alpha", "1.0 → 2.0", "delta", "5.0"} {
		if !strings.Contains(allRows, want) {
			t.Errorf("summary rows missing %q", want)
		}
	}
	for _, hidden := range []string{"/nix/store/old-home-manager-generation", "/nix/store/new-home-manager-generation"} {
		if strings.Contains(view, hidden) {
			t.Errorf("summary exposed generation path %q", hidden)
		}
	}
}

func TestRemotePlanRequiresResolvedRevision(t *testing.T) {
	m := newModel("atyrode")
	m.output = func(string, ...string) ([]byte, error) {
		return []byte(`{"source":"remote","revision":"feedfacefeed"}`), nil
	}
	msg := m.Init()().(planMsg)
	if msg.err == nil || !strings.Contains(msg.err.Error(), "full resolved revision") {
		t.Fatalf("missing resolved revision error = %v", msg.err)
	}
}

func TestPreviewMustMatchPlannedIdentity(t *testing.T) {
	m := newModel("atyrode")
	m.phase = loadingPreview
	m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", Source: "remote", ResolvedRevision: testRevision}
	result := testPreviewDocument()
	result.ResolvedRevision = strings.Repeat("b", 40)
	m.output = func(string, ...string) ([]byte, error) {
		return json.Marshal(result)
	}
	msg := m.loadPreview()().(previewMsg)
	if msg.err == nil || !strings.Contains(msg.err.Error(), "plan identity changed") {
		t.Fatalf("identity mismatch error = %v", msg.err)
	}
	next, _ := m.Update(msg)
	if next.(model).phase != failed {
		t.Fatal("identity mismatch did not fail closed")
	}
}

func TestApplyRequiresExplicitConfirmation(t *testing.T) {
	m := newModel("/bin/atyrode")
	m.phase = ready
	m.plan = applyPlan{Source: "remote", ResolvedRevision: testRevision}
	applies := 0
	var applyArgs []string
	m.apply = func(cli string, args ...string) tea.Cmd {
		applies++
		if cli != "/bin/atyrode" {
			t.Fatalf("cli = %q", cli)
		}
		applyArgs = append([]string(nil), args...)
		return func() tea.Msg { return applyDoneMsg{} }
	}

	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	m = next.(model)
	if applies != 0 || cmd != nil {
		t.Fatal("y applied without first entering confirmation")
	}

	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'a'}})
	m = next.(model)
	if m.phase != confirming || cmd != nil {
		t.Fatalf("apply key phase = %v, cmd = %v", m.phase, cmd)
	}

	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	m = next.(model)
	if m.phase != applying || applies != 1 || cmd == nil {
		t.Fatalf("confirmation phase = %v, applies = %d, cmd nil = %t", m.phase, applies, cmd == nil)
	}
	if want := []string{"apply", "--ref", testRevision}; !reflect.DeepEqual(applyArgs, want) {
		t.Fatalf("apply args = %#v, want %#v", applyArgs, want)
	}

	next, _ = m.Update(cmd())
	m = next.(model)
	if m.phase != applied || !strings.Contains(m.status, "completed") {
		t.Fatalf("completion phase = %v, status = %q", m.phase, m.status)
	}
}

func TestPreviewFailureNeverEnablesApply(t *testing.T) {
	m := newModel("atyrode")
	m.phase = loadingPreview
	next, _ := m.Update(previewMsg{err: errors.New("dry run failed")})
	m = next.(model)
	if m.phase != failed {
		t.Fatalf("phase = %v, want failed", m.phase)
	}
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if m.phase != failed || cmd != nil {
		t.Fatal("failed preview allowed apply")
	}
}

func TestDetailsToggleLabelsGenerationPaths(t *testing.T) {
	m := newModel("atyrode")
	m.phase = ready
	m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", ResolvedRevision: testRevision}
	m.preview = testPreviewDocument()

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	m = next.(model)
	if !m.details || m.cursor != 0 {
		t.Fatalf("details toggle = %t, cursor = %d", m.details, m.cursor)
	}
	view := stripTerminalControls(m.View())
	if !strings.Contains(view, "Technical details") || !strings.Contains(view, "d summary") {
		t.Errorf("details toggle not visible: %q", view)
	}
	allRows := stripTerminalControls(strings.Join(m.previewRowsForWidth(80), "\n"))
	for _, want := range []string{"Previous generation", "/nix/store/old-home-manager-generation", "New generation", "/nix/store/new-home-manager-generation", "Normalized nh report"} {
		if !strings.Contains(allRows, want) {
			t.Errorf("details rows missing %q", want)
		}
	}

	if strings.Contains(allRows, "<<< /nix/store") || strings.Contains(allRows, ">>> /nix/store") {
		t.Errorf("details rows exposed naked generation paths: %q", allRows)
	}

	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	m = next.(model)
	if m.details || strings.Contains(stripTerminalControls(m.View()), "Previous generation") {
		t.Fatal("second details toggle did not restore summary")
	}
}

func TestSummaryOmitsEmptyGroupsAndUnreportedFacts(t *testing.T) {
	m := newModel("atyrode")
	m.phase = ready
	m.preview = previewdata.Document{
		SchemaVersion:    previewdata.SchemaVersion,
		ResolvedRevision: testRevision,
		Status:           "built",
		Packages: previewdata.PackageGroups{
			Added:   []previewdata.PackageChange{},
			Updated: []previewdata.PackageChange{},
			Removed: []previewdata.PackageChange{{Name: "legacy", ChangeKind: "removed", PreviousVersion: "1.0"}},
		},
	}
	rows := stripTerminalControls(strings.Join(m.previewRowsForWidth(80), "\n"))
	for _, absent := range []string{"Added (", "Updated (", "Store paths", "Disk usage", "closure size", "Finished at", "⏱"} {
		if strings.Contains(rows, absent) {
			t.Errorf("summary exposed absent/debris fact %q: %q", absent, rows)
		}
	}
	for _, want := range []string{"1 removed", "Removed (1)", "legacy", "1.0"} {
		if !strings.Contains(rows, want) {
			t.Errorf("summary missing %q: %q", want, rows)
		}
	}
}

func TestCommandErrorStripsTerminalControls(t *testing.T) {
	err := commandError("preview apply", []byte("\x1b[2K\rbuilding\r\x1b[31mfailed\x1b[0m"), errors.New("exit status 1"))
	got := err.Error()
	if strings.ContainsAny(got, "\x1b\r") {
		t.Fatalf("terminal control escaped command error: %q", got)
	}
	if !strings.Contains(got, "failed") {
		t.Fatalf("command error lost subprocess output: %q", got)
	}
}

func TestStripTerminalControlsUsesANSIParser(t *testing.T) {
	tests := []struct {
		name, input, want string
	}{
		{"CSI", "a\x1b[31mb\x1b[0mc", "abc"},
		{"OSC BEL", "a\x1b]0;title\x07b", "ab"},
		{"OSC ST", "a\x1b]8;;https://example.test\x1b\\b\x1b]8;;\x1b\\c", "abc"},
		{"DCS", "a\x1bP1;2|payload\x1b\\b", "ab"},
		{"SOS", "a\x1bXpayload\x1b\\b", "ab"},
		{"PM", "a\x1b^payload\x1b\\b", "ab"},
		{"APC", "a\x1b_payload\x1b\\b", "ab"},
		{"BEL", "a\x07b", "ab"},
		{"C1", "a\u0085b", "ab"},
		{"truncated CSI", "a\x1b[31", "a"},
		{"truncated OSC", "a\x1b]unterminated", "a"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := stripTerminalControls(tt.input); got != tt.want {
				t.Fatalf("stripTerminalControls(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestLongPlanFailureStaysInsideNarrowWindow(t *testing.T) {
	m := newModel("atyrode")
	m.width, m.height = 44, 26
	m.output = func(string, ...string) ([]byte, error) {
		output := "\x1b]0;unsafe\x07" + strings.Repeat("plan-failure-with-an-unbroken-path/", 12)
		return []byte(output), errors.New("exit status 69")
	}
	msg := m.Init()().(planMsg)
	next, _ := m.Update(msg)
	assertFailureViewContained(t, next.(model))
}

func TestLongPreviewFailureStaysInsideNarrowWindow(t *testing.T) {
	m := newModel("atyrode")
	m.width, m.height = 44, 26
	m.plan = applyPlan{
		Host: "fixture", System: "x86_64-linux", User: "alex",
		Capabilities: []string{"base"}, Source: "remote", Revision: "feedfacefeed",
		ResolvedRevision: testRevision,
	}
	output := "\x1bPignored\x1b\\" + strings.Repeat("/nix/store/preview-failure-without-breakpoints", 10)
	err := commandError("preview apply", []byte(output), errors.New("exit status 1"))
	next, _ := m.Update(previewMsg{err: err})
	assertFailureViewContained(t, next.(model))
}

func assertFailureViewContained(t *testing.T, m model) {
	t.Helper()
	if m.phase != failed {
		t.Fatalf("phase = %v, want failed", m.phase)
	}
	lines := strings.Split(m.View(), "\n")
	if len(lines) > m.height {
		t.Errorf("failure view rendered %d rows into height %d", len(lines), m.height)
	}
	for _, line := range lines {
		if width := lipgloss.Width(line); width > m.width-1 {
			t.Errorf("failure row width = %d, safe window = %d: %q", width, m.width-1, stripTerminalControls(line))
		}
		if strings.ContainsAny(line, "\x1b\a") {
			t.Errorf("failure row retained terminal control: %q", line)
		}
	}
}

func TestPanelsKeepRightBorderWithinWindow(t *testing.T) {
	for _, windowWidth := range []int{44, 72, 80, 100} {
		m := newModel("atyrode")
		m.width, m.height, m.phase = windowWidth, 26, ready
		m.plan = applyPlan{
			Host:         "alex-x86_64-linux",
			System:       "x86_64-linux",
			User:         "alex",
			Installable:  "github:atyrode/dotfiles/11bbf08875fa8b8428b1fb2d9814a0957e1ec3b0#alex-x86_64-linux",
			Revision:     "11bbf08875fa",
			Source:       "remote",
			Backend:      "nh-home",
			Capabilities: []string{"base", "development", "agent-tools", "containers"},
		}
		m.preview = testPreviewDocument()

		for _, details := range []bool{false, true} {
			m.details = details
			renderedLines := strings.Split(m.View(), "\n")
			if len(renderedLines) > m.height {
				t.Errorf("window %d details=%t rendered %d rows into height %d", windowWidth, details, len(renderedLines), m.height)
			}
			for _, line := range renderedLines {
				if width := lipgloss.Width(line); width > windowWidth-1 {
					t.Errorf("rendered row width = %d, safe window = %d: %q", width, windowWidth-1, stripTerminalControls(line))
				}
				plain := stripTerminalControls(line)
				if strings.ContainsAny(plain, "╭│╰") && !strings.HasSuffix(plain, "╮") && !strings.HasSuffix(plain, "│") && !strings.HasSuffix(plain, "╯") {
					t.Errorf("window %d details=%t panel row lost right border: %q", windowWidth, details, plain)
				}
			}
		}
	}
}

func TestCapabilityChipsAdaptToAvailableWidth(t *testing.T) {
	capabilities := []string{"base", "development", "agent-tools", "containers"}
	rendered := capabilityChips(capabilities, 36)
	lines := strings.Split(rendered, "\n")
	if len(lines) < 2 {
		t.Fatal("capability chips did not wrap")
	}
	for _, line := range lines {
		if width := lipgloss.Width(line); width > 50 {
			t.Errorf("indented chip row width = %d, want <= 50: %q", width, stripTerminalControls(line))
		}
	}
	compact := stripTerminalControls(capabilityChips(capabilities, 18))
	if compact != " 4 active " {
		t.Fatalf("compact capabilities = %q", compact)
	}
}
