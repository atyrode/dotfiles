package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	inventorydata "atyrode-tui/inventory"
	previewdata "atyrode-tui/preview"
	clikit "github.com/atyrode/cli-kit"
	ompkit "github.com/atyrode/cli-kit/omp"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const testRevision = "feedfacefeedfacefeedfacefeedfacefeedface"

type runnerFunc func(context.Context, string, ...string) ([]byte, error)

func (f runnerFunc) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	return f(ctx, name, args...)
}

func TestExecCommandRunnerKeepsJSONSeparateFromStderr(t *testing.T) {
	runner := execCommandRunner{}
	out, err := runner.Output(context.Background(), "/bin/sh", "-c", `printf '{"ok":true}'; printf 'progress' >&2`)
	if err != nil || string(out) != `{"ok":true}` {
		t.Fatalf("successful split output = %q, %v", out, err)
	}
	out, err = runner.Output(context.Background(), "/bin/sh", "-c", `printf '{"ok":false}'; printf 'diagnostic' >&2; exit 65`)
	if string(out) != `{"ok":false}` || err == nil || !strings.Contains(err.Error(), "diagnostic") {
		t.Fatalf("failed split output = %q, %v", out, err)
	}
}

func newApplyTestModel(cli string) model {
	m := newModel(cli)
	m.nav.Select(workspaceApply)
	m.applyRequested = true
	return m
}

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
func testInventoryDocument() inventorydata.Manifest {
	return inventorydata.Manifest{
		SchemaVersion: inventorydata.SchemaVersion,
		Identity: inventorydata.Identity{
			Revision: testRevision,
			System:   "x86_64-linux",
			Platform: "linux",
		},
		Capabilities: map[string]inventorydata.Capability{
			"base": {
				Name: "base", Title: "Base", Purpose: "Shell and operator baseline", Applicable: true,
				DeliveryBoundary: "Home Manager", MutableState: "Caches only", SecurityBoundary: "No credentials",
				Deliverables: []inventorydata.Deliverable{
					{Kind: "package", Name: "git", Version: "2.50", Description: "Distributed version control", Delivery: "home-manager", Source: "pinned-nixpkgs", System: "x86_64-linux", Platform: "linux"},
					{Kind: "package", Name: "gh", Version: "2.75", Description: "GitHub command-line client", Delivery: "home-manager", Source: "pinned-nixpkgs", System: "x86_64-linux", Platform: "linux"},
				},
			},
			"agents": {
				Name: "agents", Title: "Agent tools", Purpose: "Managed agent tools and configuration", Applicable: true,
				DeliveryBoundary: "Home Manager and overlays", MutableState: "Sessions stay mutable", SecurityBoundary: "Credentials are excluded",
				Deliverables: []inventorydata.Deliverable{
					{Kind: "application", Name: "omp", Version: "1.2", Description: "Agent orchestration cockpit with a deliberately long description for responsive wrapping", Delivery: "home-manager", Source: "repository-overlay", System: "x86_64-linux", Platform: "linux"},
				},
			},
			"server": {
				Name: "server", Title: "Server", Purpose: "Linux-only headless composition marker", Applicable: true, Marker: true,
				DeliveryBoundary: "Marker capability", MutableState: "System-owned", SecurityBoundary: "No production facts",
				Deliverables: []inventorydata.Deliverable{},
			},
		},
		Hosts: map[string]inventorydata.Host{
			"workstation": {ID: "workstation", Aliases: []string{"desk"}, Platform: "linux", System: "x86_64-linux", Capabilities: []string{"base", "agents", "server"}},
		},
	}
}

type recordingAsker struct {
	docs   clikit.DocCorpus
	chunks []string
}

func (a *recordingAsker) Ask(context.Context, string) (<-chan string, error) {
	ch := make(chan string, len(a.chunks))
	for _, chunk := range a.chunks {
		ch <- chunk
	}
	close(ch)
	return ch, nil
}

func TestAskGroundingComesFromCLIHelp(t *testing.T) {
	help := []byte(`Usage:
  atyrode apply [HOST] [--ref REF] [--repo PATH] [--plan|--dry-run|--preview-json] [--json] [--restart-shell]
apply preview modes are non-activating: --plan resolves and validates the target
then prints preflight metadata without invoking nh; --dry-run invokes the normal
nh switch backend with --dry; --preview-json runs that dry backend and emits its
normalized package/action preview as JSON.
`)
	docs, err := buildAskGrounding(help)
	if err != nil {
		t.Fatal(err)
	}
	got := string(docs)
	for _, want := range []string{"atyrode apply [HOST]", "--plan resolves and validates the target", "--dry-run invokes the normal", "--preview-json runs that dry backend", "read-only", "Do not invent"} {
		if !strings.Contains(got, want) {
			t.Errorf("grounding missing %q: %q", want, got)
		}
	}
	if _, err := buildAskGrounding([]byte("not command help")); err == nil {
		t.Fatal("unrecognizable help unexpectedly produced grounding")
	}
	if backend, ok := newAskBackend(docs).(ompkit.Asker); !ok || !backend.ReplaceSystem {
		t.Fatal("atyrode Ask backend did not isolate its grounded system prompt")
	}
}

func TestGroundedAskerStreamsCompletionAndCachesHelp(t *testing.T) {
	loadCalls := 0
	var backend *recordingAsker
	asker := &groundedAsker{
		cli: "atyrode",
		grounding: func(context.Context, string) ([]byte, error) {
			loadCalls++
			return []byte("Usage:\n  atyrode generations [--json] [--sizes]\n"), nil
		},
		backend: func(docs clikit.DocCorpus) clikit.Asker {
			backend = &recordingAsker{docs: docs, chunks: []string{"first", " second"}}
			return backend
		},
	}

	for range 2 {
		stream, err := asker.Ask(context.Background(), "how do generations work?")
		if err != nil {
			t.Fatal(err)
		}
		var answer strings.Builder
		for chunk := range stream {
			answer.WriteString(chunk)
		}
		if got := answer.String(); got != "first second" {
			t.Fatalf("streamed answer = %q", got)
		}
	}
	if loadCalls != 1 {
		t.Fatalf("--help loads = %d, want one cached load", loadCalls)
	}
	if backend == nil || !strings.Contains(string(backend.docs), "atyrode generations") {
		t.Fatal("backend did not receive CLI-derived grounding")
	}
}

type cancellingAsker struct{}

func (cancellingAsker) Ask(ctx context.Context, _ string) (<-chan string, error) {
	ch := make(chan string)
	go func() {
		defer close(ch)
		<-ctx.Done()
	}()
	return ch, nil
}

func TestGroundedAskerCancellationClosesStream(t *testing.T) {
	asker := &groundedAsker{
		cli: "atyrode",
		grounding: func(context.Context, string) ([]byte, error) {
			return []byte("Usage:\n  atyrode host [HOST] [--json]\n"), nil
		},
		backend: func(clikit.DocCorpus) clikit.Asker { return cancellingAsker{} },
	}
	ctx, cancel := context.WithCancel(context.Background())
	stream, err := asker.Ask(ctx, "which host?")
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	select {
	case _, ok := <-stream:
		if ok {
			t.Fatal("cancelled stream produced a token")
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled stream did not close")
	}
}

func TestOverviewStartsWithoutApplyWorkAndApplyPreviewRemainsExplicit(t *testing.T) {
	var calls [][]string
	m := newModel("/bin/atyrode")
	m.runner = runnerFunc(func(_ context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		switch {
		case reflect.DeepEqual(args, []string{"apply", "--plan", "--json"}):
			return []byte(`{"host":"workstation","system":"x86_64-linux","user":"alex","capabilities":["base","agents"],"installable":"github:atyrode/dotfiles/feedfacefeedfacefeedfacefeedfacefeedface#workstation","revision":"feedfacefeed","resolvedRevision":"feedfacefeedfacefeedfacefeedfacefeedface","source":"remote"}`), nil
		case reflect.DeepEqual(args, []string{"apply", "--ref", testRevision, "--preview-json"}):
			return json.Marshal(testPreviewDocument())
		default:
			t.Fatalf("unexpected command: %s %v", name, args)
			return nil, nil
		}
	})

	if cmd := m.Init(); cmd != nil {
		t.Fatal("Overview startup unexpectedly scheduled an Apply command")
	}
	if len(calls) != 0 {
		t.Fatalf("Overview startup commands = %#v, want none", calls)
	}
	overview := stripTerminalControls(m.View())
	for _, want := range []string{"ATYRODE", "Your Nix operating environment", "1. Overview", "2. Apply", "Tab/Shift+Tab navigate"} {
		if !strings.Contains(overview, want) {
			t.Errorf("Overview missing %q", want)
		}
	}

	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'2'}})
	m = next.(model)
	if cmd == nil || m.nav.Active() != workspaceApply || m.phase != loadingPlan {
		t.Fatalf("enter Apply state = active %q phase %v cmd %v", m.nav.Active(), m.phase, cmd)
	}
	plan := cmd().(planMsg)
	next, cmd = m.Update(plan)
	m = next.(model)
	if cmd != nil || m.phase != ready {
		t.Fatalf("plan completion phase/cmd = %v/%v, want ready/nil", m.phase, cmd)
	}
	if want := [][]string{{"/bin/atyrode", "apply", "--plan", "--json"}}; !reflect.DeepEqual(calls, want) {
		t.Fatalf("Apply entry commands = %#v, want %#v", calls, want)
	}
	unloaded := stripTerminalControls(m.View())
	for _, want := range []string{"workstation", "feedfacefeed", "Preview not loaded", "v preview", "enter apply"} {
		if !strings.Contains(unloaded, want) {
			t.Errorf("unloaded ready view missing %q", want)
		}
	}

	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'v'}})
	m = next.(model)
	if !m.previewLoading || cmd == nil || m.phase != ready {
		t.Fatalf("preview start loading/cmd/phase = %t/%v/%v", m.previewLoading, cmd, m.phase)
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	wantCalls := [][]string{
		{"/bin/atyrode", "apply", "--plan", "--json"},
		{"/bin/atyrode", "apply", "--ref", testRevision, "--preview-json"},
	}
	if !reflect.DeepEqual(calls, wantCalls) {
		t.Fatalf("commands = %#v, want %#v", calls, wantCalls)
	}
	if m.phase != ready || m.previewLoading || m.preview.SchemaVersion == 0 {
		t.Fatalf("preview completion state = phase %v loading %t schema %d", m.phase, m.previewLoading, m.preview.SchemaVersion)
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{"ACTIVATION PREVIEW", "Applying revision feedfacefeed", "Preview built", "1 added", "2 updated", "1 removed", "Disk usage decreases by 5.59 MiB"} {
		if !strings.Contains(view, want) {
			t.Errorf("visible summary missing %q", want)
		}
	}
}

func TestWorkspaceTabsStayAlignedAndOnlyMoveSelection(t *testing.T) {
	m := newModel("atyrode")
	for _, tc := range []struct {
		width int
		rows  int
	}{{34, 3}, {64, 2}, {92, 2}, {142, 1}} {
		tabs := m.workspaceTabs(tc.width)
		lines := strings.Split(tabs, "\n")
		if len(lines) != tc.rows {
			t.Fatalf("tabs at width %d rendered %d rows, want %d", tc.width, len(lines), tc.rows)
		}
		for _, line := range lines {
			if got := lipgloss.Width(line); got != tc.width {
				t.Fatalf("tabs at width %d rendered row width %d", tc.width, got)
			}
		}
	}

	overview := m.workspaceTabs(142)
	m.nav.Select(workspaceApply)
	apply := m.workspaceTabs(142)
	if stripTerminalControls(overview) != stripTerminalControls(apply) {
		t.Fatal("selecting a workspace moved or changed tab labels")
	}
	if fmt.Sprint(workspaceTabStyle(20, false).GetBackground()) == fmt.Sprint(workspaceTabStyle(20, true).GetBackground()) {
		t.Fatal("selected workspace tab has no distinct background")
	}
	if !strings.Contains(stripTerminalControls(m.workspaceTabs(34)), "3. Gen / Clean") {
		t.Fatal("narrow workspace tabs obscured the Generations / Clean destination")
	}
	for _, want := range []string{"1. Overview", "2. Apply", "3. Generations / Clean", "4. Doctor", "5. Capabilities", "6. Ask"} {
		if !strings.Contains(stripTerminalControls(apply), want) {
			t.Fatalf("workspace tabs missing %q", want)
		}
	}
}

func TestWorkspaceNavigationPreservesApplyState(t *testing.T) {
	m := newModel("atyrode")
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`{"host":"workstation","system":"x86_64-linux","resolvedRevision":"` + testRevision + `"}`), nil
	})

	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = next.(model)
	if m.nav.Active() != workspaceApply || cmd == nil {
		t.Fatalf("Tab entered %q with cmd %v, want Apply load", m.nav.Active(), cmd)
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	m.previewCursor = 3

	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = next.(model)
	if m.nav.Active() != workspaceLifecycle || cmd == nil {
		t.Fatalf("second Tab entered %q with cmd %v, want lifecycle load", m.nav.Active(), cmd)
	}
	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyShiftTab})
	m = next.(model)
	if m.nav.Active() != workspaceApply || cmd != nil || m.previewCursor != 3 || m.plan.Host != "workstation" {
		t.Fatalf("Apply state was not retained: active=%q cmd=%v cursor=%d host=%q", m.nav.Active(), cmd, m.previewCursor, m.plan.Host)
	}

	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'4'}})
	m = next.(model)
	if m.nav.Active() != workspaceDoctor {
		t.Fatalf("direct shortcut entered %q, want Doctor", m.nav.Active())
	}
}

func TestOverviewAndAskStayWithinRepresentativeWindows(t *testing.T) {
	for _, size := range []struct{ width, height int }{{44, 18}, {80, 26}, {100, 30}, {150, 44}} {
		m := newModel("atyrode")
		m.width, m.height = size.width, size.height
		m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", Revision: "feedfacefeed"}
		for _, workspace := range []clikit.WorkspaceID{workspaceOverview, workspaceAsk} {
			m.nav.Select(workspace)
			view := m.View()
			if rows := strings.Split(view, "\n"); len(rows) > m.height {
				t.Errorf("%s at %dx%d rendered %d rows", workspace, m.width, m.height, len(rows))
			}
			for _, row := range strings.Split(view, "\n") {
				if got := lipgloss.Width(row); got >= m.width {
					t.Errorf("%s at %dx%d rendered row width %d: %q", workspace, m.width, m.height, got, stripTerminalControls(row))
				}
			}
		}
	}
}

func TestRemotePlanRequiresResolvedRevision(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`{"source":"remote","revision":"feedfacefeed"}`), nil
	})
	msg := m.loadPlan()().(planMsg)
	if msg.err == nil || !strings.Contains(msg.err.Error(), "full resolved revision") {
		t.Fatalf("missing resolved revision error = %v", msg.err)
	}
}

func TestPreviewMustMatchPlannedIdentity(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.phase = ready
	m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", Source: "remote", ResolvedRevision: testRevision}
	result := testPreviewDocument()
	result.ResolvedRevision = strings.Repeat("b", 40)
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return json.Marshal(result)
	})
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'v'}})
	m = next.(model)
	next, _ = m.Update(cmd())
	m = next.(model)
	if m.previewErr == nil || !strings.Contains(m.previewErr.Error(), "plan identity changed") {
		t.Fatalf("identity mismatch error = %v", m.previewErr)
	}
	if m.phase != ready {
		t.Fatal("identity mismatch blocked the validated plan")
	}
}

func TestApplyRequiresExplicitConfirmation(t *testing.T) {
	m := newApplyTestModel("/bin/atyrode")
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

func TestPreviewFailureIsPanelLocalAndApplyRemainsAvailable(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.phase = ready
	m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", ResolvedRevision: testRevision}
	m.previewGeneration = 3
	next, _ := m.Update(previewMsg{revision: testRevision, generation: 3, err: errors.New("dry run failed")})
	m = next.(model)
	if m.phase != ready || m.previewErr == nil || m.err != nil {
		t.Fatalf("preview failure escaped panel: phase=%v previewErr=%v err=%v", m.phase, m.previewErr, m.err)
	}
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if m.phase != confirming || cmd != nil {
		t.Fatal("failed preview blocked apply confirmation")
	}
	view := stripTerminalControls(m.View())
	for _, want := range []string{"Preview unavailable", "dry run failed", "y confirm"} {
		if !strings.Contains(view, want) {
			t.Errorf("local failure view missing %q", want)
		}
	}
}

func TestPreviewLoadingRemainsResponsiveAndCancellationIsStaleSafe(t *testing.T) {
	for _, key := range []string{"a", "v", "r", "q"} {
		t.Run(key, func(t *testing.T) {
			started, cancelled := make(chan struct{}), make(chan struct{})
			m := newApplyTestModel("atyrode")
			m.phase = ready
			m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", Source: "remote", ResolvedRevision: testRevision}
			m.runner = runnerFunc(func(ctx context.Context, _ string, args ...string) ([]byte, error) {
				if !reflect.DeepEqual(args, []string{"apply", "--ref", testRevision, "--preview-json"}) {
					t.Fatalf("preview args = %#v", args)
				}
				close(started)
				<-ctx.Done()
				close(cancelled)
				return nil, ctx.Err()
			})

			next, previewCmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'v'}})
			m = next.(model)
			if previewCmd == nil || !m.previewLoading || m.phase != ready {
				t.Fatal("preview did not start in non-blocking ready state")
			}
			result := make(chan tea.Msg, 1)
			go func() { result <- previewCmd() }()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("preview runner did not start")
			}

			m = press(m, "j")
			if m.phase != ready || !strings.Contains(stripTerminalControls(m.View()), "Apply controls remain available") {
				t.Fatal("loading preview made the model unresponsive")
			}
			next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
			m = next.(model)
			select {
			case <-cancelled:
			case <-time.After(time.Second):
				t.Fatalf("%q did not cancel preview context", key)
			}
			if m.previewLoading {
				t.Fatalf("%q left preview loading", key)
			}
			if key == "a" && m.phase != confirming {
				t.Fatalf("apply key phase = %v, want confirming", m.phase)
			}
			stale := <-result
			next, _ = m.Update(stale)
			after := next.(model)
			if after.previewErr != nil || after.preview.SchemaVersion != 0 {
				t.Fatalf("stale cancellation reply changed preview: %#v / %v", after.preview, after.previewErr)
			}
		})
	}
}

func TestPreviewRepliesAreScopedToRevisionAndGeneration(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.phase = ready
	m.plan.ResolvedRevision = testRevision
	m.previewGeneration = 9
	current := testPreviewDocument()
	next, _ := m.Update(previewMsg{revision: testRevision, generation: 9, preview: current})
	m = next.(model)
	for _, stale := range []previewMsg{
		{revision: strings.Repeat("a", 40), generation: 9, err: errors.New("wrong revision")},
		{revision: testRevision, generation: 8, err: errors.New("old failure")},
		{revision: testRevision, generation: 10, preview: previewdata.Document{SchemaVersion: previewdata.SchemaVersion}},
	} {
		next, _ = m.Update(stale)
		m = next.(model)
		if !reflect.DeepEqual(m.preview, current) || m.previewErr != nil {
			t.Fatalf("stale preview reply mutated current state: %#v / %v", m.preview, m.previewErr)
		}
	}
}

func TestConfirmationExplainsOptionalPreviewStatus(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.phase = ready
	m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", ResolvedRevision: testRevision}
	m = press(m, "enter")
	without := stripTerminalControls(m.View())
	if !strings.Contains(without, "Optional dry preview was not run.") || !strings.Contains(without, "y confirm") {
		t.Fatalf("no-preview confirmation was not explicit: %q", without)
	}

	m.phase, m.preview = ready, testPreviewDocument()
	m = press(m, "enter")
	with := stripTerminalControls(m.View())
	if !strings.Contains(with, "Preview built") || !strings.Contains(with, "y confirm") ||
		strings.Contains(with, "Optional dry preview was not run.") {
		t.Fatalf("loaded-preview confirmation status = %q", with)
	}
}

func TestDetailsToggleLabelsGenerationPaths(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.phase = ready
	m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", ResolvedRevision: testRevision}
	m.preview = testPreviewDocument()

	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'d'}})
	m = next.(model)
	if !m.details || m.previewCursor != 0 {
		t.Fatalf("details toggle = %t, cursor = %d", m.details, m.previewCursor)
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
	m := newApplyTestModel("atyrode")
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
	m := newApplyTestModel("atyrode")
	m.width, m.height = 44, 26
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		output := "\x1b]0;unsafe\x07" + strings.Repeat("plan-failure-with-an-unbroken-path/", 12)
		return []byte(output), errors.New("exit status 69")
	})
	msg := m.loadPlan()().(planMsg)
	next, _ := m.Update(msg)
	assertFailureViewContained(t, next.(model))
}

func TestLongPreviewFailureStaysInsideNarrowWindow(t *testing.T) {
	m := newApplyTestModel("atyrode")
	m.width, m.height, m.phase = 44, 26, ready
	m.plan = applyPlan{
		Host: "fixture", System: "x86_64-linux", User: "alex",
		Capabilities: []string{"base"}, Source: "remote", Revision: "feedfacefeed",
		ResolvedRevision: testRevision,
	}
	output := "\x1bPignored\x1b\\" + strings.Repeat("/nix/store/preview-failure-without-breakpoints", 10)
	m.previewGeneration = 4
	err := commandError("preview apply", []byte(output), errors.New("exit status 1"))
	next, _ := m.Update(previewMsg{revision: testRevision, generation: 4, err: err})
	m = next.(model)
	if m.phase != ready || m.previewErr == nil {
		t.Fatalf("preview error blocked ready state: phase=%v err=%v", m.phase, m.previewErr)
	}
	lines := strings.Split(m.View(), "\n")
	if len(lines) > m.height {
		t.Errorf("preview failure view rendered %d rows into height %d", len(lines), m.height)
	}
	for _, line := range lines {
		if width := lipgloss.Width(line); width > m.width-1 {
			t.Errorf("preview failure row width = %d, safe window = %d: %q", width, m.width-1, stripTerminalControls(line))
		}
	}
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
		m := newApplyTestModel("atyrode")
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

func readyInventoryModel(width int) model {
	m := newApplyTestModel("atyrode")
	m.width, m.height, m.phase = width, 34, ready
	m.plan = applyPlan{
		Host: "workstation", System: "x86_64-linux", User: "alex", Source: "remote",
		ResolvedRevision: testRevision, Revision: "feedfacefeed", Capabilities: []string{"base", "agents", "server"},
	}
	m.preview = testPreviewDocument()
	data, _ := json.Marshal(testInventoryDocument())
	m.inventory, _ = inventorydata.Parse(data, inventorydata.Expected{
		Revision: testRevision, System: "x86_64-linux", Host: "workstation",
		ActiveCapabilities: m.plan.Capabilities,
	})
	m.inventoryRequested = true
	return m
}

func press(m model, key string) model {
	var msg tea.KeyMsg
	switch key {
	case "tab":
		msg = tea.KeyMsg{Type: tea.KeyTab}
	case "esc":
		msg = tea.KeyMsg{Type: tea.KeyEsc}
	case "up":
		msg = tea.KeyMsg{Type: tea.KeyUp}
	case "down":
		msg = tea.KeyMsg{Type: tea.KeyDown}
	case "left":
		msg = tea.KeyMsg{Type: tea.KeyLeft}
	case "right":
		msg = tea.KeyMsg{Type: tea.KeyRight}
	case "enter":
		msg = tea.KeyMsg{Type: tea.KeyEnter}
	default:
		msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}
	}
	next, _ := m.Update(msg)
	return next.(model)
}

func TestCapabilityCyclingWrapsBothDirectionsInPlanOrder(t *testing.T) {
	m := readyInventoryModel(100)
	m = press(m, "c")
	if m.focus != capabilityPane || !m.capabilitiesOpen {
		t.Fatal("c did not open and focus capabilities")
	}
	m = press(m, "[")
	if m.selectedCapability != 2 || m.inventory.Capabilities[2].Name != "server" {
		t.Fatalf("backward wrap selected %d", m.selectedCapability)
	}
	m = press(m, "]")
	if m.selectedCapability != 0 || m.inventory.Capabilities[0].Name != "base" {
		t.Fatalf("forward wrap selected %d", m.selectedCapability)
	}
	m = press(m, "right")
	if m.inventory.Capabilities[m.selectedCapability].Name != "agents" {
		t.Fatal("right-arrow alternative did not cycle forward")
	}
}

func TestCapabilityFocusAndIndependentScrollSurviveReturn(t *testing.T) {
	m := readyInventoryModel(140)
	m.previewCursor = 3
	m = press(m, "c")
	if m.focus != capabilityPane {
		t.Fatal("c did not move focus to capability pane")
	}
	for range 5 {
		m = press(m, "j")
	}
	capabilityCursor := m.capabilityCursor
	if capabilityCursor == 0 {
		t.Fatal("focused capability pane did not scroll")
	}
	m = press(m, "c")
	if m.focus != previewPane || m.previewCursor != 3 || m.capabilityCursor != capabilityCursor {
		t.Fatalf("return lost pane state: focus=%v preview=%d capability=%d", m.focus, m.previewCursor, m.capabilityCursor)
	}
	m = press(m, "c")
	if m.focus != capabilityPane || m.capabilityCursor != capabilityCursor {
		t.Fatal("reopening capabilities reset its scroll")
	}
	m = press(m, "esc")
	if m.focus != previewPane || m.capabilityCursor != capabilityCursor {
		t.Fatal("Esc did not preserve capability scroll")
	}
}

func flattened(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func TestCapabilityRowsGroupItemsAndExplainEmptyAndPlatformStates(t *testing.T) {
	m := readyInventoryModel(100)
	base := flattened(stripTerminalControls(strings.Join(m.capabilityRowsForWidth(36), "\n")))
	for _, want := range []string{"Base 1/3", "ACTIVE · 2 items", "Packages (2)", "Distributed version control", "git · 2.50 · pinned-nixpkgs", "via home-manager", "for x86_64-linux", "Delivery boundary", "Security boundary", "Mutable state"} {
		if !strings.Contains(base, want) {
			t.Errorf("base capability missing %q:\n%s", want, base)
		}
	}
	if strings.Contains(base, "Applications (") {
		t.Fatal("empty deliverable group was rendered")
	}

	m.selectedCapability = 2
	server := flattened(stripTerminalControls(strings.Join(m.capabilityRowsForWidth(30), "\n")))
	for _, want := range []string{"Server 3/3", "0 items", "Intentional marker", "no direct deliverables"} {
		if !strings.Contains(server, want) {
			t.Errorf("server marker missing %q:\n%s", want, server)
		}
	}

	m.selectedCapability = 1
	m.inventory.Capabilities[1].Applicable = false
	conditional := flattened(stripTerminalControls(strings.Join(m.capabilityRowsForWidth(24), "\n")))
	if !strings.Contains(conditional, "NOT APPLICABLE ON LINUX") {
		t.Fatalf("platform condition was not textual:\n%s", conditional)
	}
	for _, line := range m.capabilityRowsForWidth(24) {
		if lipgloss.Width(line) > 24 {
			t.Errorf("long capability text exceeded width: %q", stripTerminalControls(line))
		}
	}
}

func TestInventoryLoadingAndFailureNeverAlterApplyConfirmation(t *testing.T) {
	m := readyInventoryModel(72)
	m.inventory, m.inventoryLoading = inventorydata.Document{}, true
	loading := flattened(stripTerminalControls(strings.Join(m.capabilityRowsForWidth(30), "\n")))
	if !strings.Contains(loading, "Loading exact-revision inventory") {
		t.Fatalf("loading state = %q", loading)
	}
	m.inventoryLoading = false
	m.inventoryErr = errors.New("inventory revision mismatch: got deadbeef, need feedface")
	failure := flattened(stripTerminalControls(strings.Join(m.capabilityRowsForWidth(30), "\n")))
	for _, want := range []string{"Inventory unavailable", "revision mismatch", "apply confirmation remain available"} {
		if !strings.Contains(failure, want) {
			t.Errorf("failure state missing %q: %q", want, failure)
		}
	}
	m = press(m, "enter")
	if m.phase != confirming {
		t.Fatal("inventory failure disabled confirmation")
	}
	m = press(m, "n")
	if m.phase != ready {
		t.Fatal("inventory failure disabled confirmation cancel")
	}
	applies := 0
	m.apply = func(string, ...string) tea.Cmd {
		applies++
		return func() tea.Msg { return applyDoneMsg{} }
	}
	m = press(m, "enter")
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	m = next.(model)
	if m.phase != applying || applies != 1 || cmd == nil {
		t.Fatalf("inventory failure blocked confirmed apply: phase=%v applies=%d", m.phase, applies)
	}
}

func TestCapabilityInventoryIsLazyExactRevisionAndRequestedOnce(t *testing.T) {
	var calls [][]string
	m := newApplyTestModel("/bin/atyrode")
	m.phase = ready
	m.plan = applyPlan{
		Host: "workstation", System: "x86_64-linux", Source: "remote",
		ResolvedRevision: testRevision, Capabilities: []string{"base", "agents", "server"},
	}
	m.runner = runnerFunc(func(_ context.Context, name string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string{name}, args...))
		return json.Marshal(testInventoryDocument())
	})
	if m.inventoryRequested || m.inventoryLoading {
		t.Fatal("inventory was requested before capability inspection")
	}
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
	m = next.(model)
	if cmd == nil || !m.inventoryRequested || !m.inventoryLoading || m.focus != capabilityPane {
		t.Fatalf("first c state = cmd %v requested %t loading %t focus %v", cmd, m.inventoryRequested, m.inventoryLoading, m.focus)
	}
	next, _ = m.Update(cmd())
	m = next.(model)
	want := [][]string{{"/bin/atyrode", "inventory", "--ref", testRevision, "--json"}}
	if !reflect.DeepEqual(calls, want) || m.inventoryLoading || len(m.inventory.Capabilities) != 3 {
		t.Fatalf("inventory calls/state = %#v loading=%t capabilities=%d", calls, m.inventoryLoading, len(m.inventory.Capabilities))
	}
	m = press(m, "c")
	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
	m = next.(model)
	if cmd != nil || len(calls) != 1 {
		t.Fatalf("reopening inventory started another request: cmd=%v calls=%#v", cmd, calls)
	}
}

func TestInspectionRequestsNeverOverlap(t *testing.T) {
	previewing := newApplyTestModel("atyrode")
	previewing.phase = ready
	previewing.plan.ResolvedRevision = testRevision
	previewing.previewLoading = true
	next, cmd := previewing.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
	previewing = next.(model)
	if cmd != nil || previewing.inventoryRequested {
		t.Fatal("capability inspection overlapped a running preview")
	}

	inventoryLoading := newApplyTestModel("atyrode")
	inventoryLoading.phase = ready
	inventoryLoading.plan.ResolvedRevision = testRevision
	inventoryLoading.inventoryRequested, inventoryLoading.inventoryLoading = true, true
	next, cmd = inventoryLoading.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'v'}})
	inventoryLoading = next.(model)
	if cmd != nil || inventoryLoading.previewLoading {
		t.Fatal("preview overlapped a running capability inventory")
	}
}

func TestInventoryContextIsCancelledByRefreshAndQuit(t *testing.T) {
	for _, key := range []string{"r", "q"} {
		t.Run(key, func(t *testing.T) {
			started, cancelled := make(chan struct{}), make(chan struct{})
			m := newApplyTestModel("atyrode")
			m.phase = ready
			m.plan = applyPlan{Host: "workstation", System: "x86_64-linux", ResolvedRevision: testRevision}
			m.runner = runnerFunc(func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
				close(started)
				<-ctx.Done()
				close(cancelled)
				return nil, ctx.Err()
			})
			next, inventoryCmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'c'}})
			m = next.(model)
			result := make(chan tea.Msg, 1)
			go func() { result <- inventoryCmd() }()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("inventory runner did not start")
			}
			next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
			m = next.(model)
			select {
			case <-cancelled:
			case <-time.After(time.Second):
				t.Fatalf("%q did not cancel inventory context", key)
			}
			stale := <-result
			next, _ = m.Update(stale)
			after := next.(model)
			if len(after.inventory.Capabilities) != 0 || after.inventoryErr != nil {
				t.Fatalf("stale inventory cancellation reply changed state: %#v / %v", after.inventory, after.inventoryErr)
			}
		})
	}
}

func TestPreviewStatesStayResponsiveAtRepresentativeWidths(t *testing.T) {
	states := []struct {
		name string
		set  func(*model)
		want string
	}{
		{name: "unloaded", set: func(m *model) { m.preview = previewdata.Document{} }, want: "Preview not loaded"},
		{name: "loading", set: func(m *model) { m.preview, m.previewLoading = previewdata.Document{}, true }, want: "Loading optional dry"},
		{name: "failure", set: func(m *model) { m.preview, m.previewErr = previewdata.Document{}, errors.New("fixture failure") }, want: "Preview unavailable"},
		{name: "loaded", set: func(m *model) { m.preview = testPreviewDocument() }, want: "Preview built"},
	}
	for _, width := range []int{140, 100, 72, 44} {
		for _, state := range states {
			t.Run(fmt.Sprintf("%d/%s", width, state.name), func(t *testing.T) {
				m := readyInventoryModel(width)
				m.height = 30
				m.previewLoading, m.previewErr = false, nil
				state.set(&m)
				rendered := m.View()
				if !strings.Contains(flattened(stripTerminalControls(rendered)), state.want) {
					t.Fatalf("state marker %q missing from:\n%s", state.want, stripTerminalControls(rendered))
				}
				lines := strings.Split(rendered, "\n")
				if len(lines) > m.height {
					t.Fatalf("rendered %d rows into height %d", len(lines), m.height)
				}
				for _, line := range lines {
					if got := lipgloss.Width(line); got > width-1 {
						t.Fatalf("row overflowed width %d at %d: %q", width, got, stripTerminalControls(line))
					}
				}
			})
		}
	}
}

func TestCapabilityResponsiveLayoutsStayWithinTerminal(t *testing.T) {
	for _, width := range []int{140, 100, 72, 44} {
		m := readyInventoryModel(width)
		if !m.isWide() {
			m = press(m, "c")
		}
		rendered := m.View()
		lines := strings.Split(rendered, "\n")
		if len(lines) > m.height {
			t.Errorf("width %d rendered %d rows into height %d", width, len(lines), m.height)
		}
		for _, line := range lines {
			if got := lipgloss.Width(line); got > width-1 {
				t.Errorf("width %d row overflowed at %d: %q", width, got, stripTerminalControls(line))
			}
		}
		plain := stripTerminalControls(rendered)
		if !strings.Contains(plain, "CAPABILITIES") {
			t.Errorf("width %d did not render capability view", width)
		}
		if width == 140 && !strings.Contains(plain, "ACTIVATION PREVIEW") {
			t.Fatal("wide layout did not preserve split preview")
		}
	}
}

func TestInventoryRepliesAreScopedToRevisionAndGeneration(t *testing.T) {
	currentRevision := strings.Repeat("a", 40)
	currentDocument := inventorydata.Document{
		Identity:     inventorydata.Identity{Revision: currentRevision},
		Capabilities: []inventorydata.Capability{{Name: "current"}},
	}
	staleDocument := inventorydata.Document{
		Identity:     inventorydata.Identity{Revision: testRevision},
		Capabilities: []inventorydata.Capability{{Name: "stale"}},
	}
	tests := []struct {
		name    string
		current inventoryMsg
		stale   inventoryMsg
	}{
		{
			name:    "A failure after B success",
			current: inventoryMsg{revision: currentRevision, generation: 8, inventory: currentDocument},
			stale: inventoryMsg{
				revision: testRevision, generation: 7, err: errors.New("stale failure"),
				diagnostic: "stale diagnostic",
			},
		},
		{
			name: "A success after B failure",
			current: inventoryMsg{
				revision: currentRevision, generation: 8, err: errors.New("current failure"),
				diagnostic: "current diagnostic",
			},
			stale: inventoryMsg{revision: testRevision, generation: 7, inventory: staleDocument},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := newApplyTestModel("atyrode")
			m.plan.ResolvedRevision = currentRevision
			m.inventoryGeneration, m.inventoryRequested, m.inventoryLoading = 8, true, true

			next, _ := m.Update(tt.current)
			m = next.(model)
			wantInventory, wantErr := m.inventory, m.inventoryErr
			wantDiagnostic, wantLoading := m.inventoryDiagnostic, m.inventoryLoading

			next, _ = m.Update(tt.stale)
			m = next.(model)
			if !reflect.DeepEqual(m.inventory, wantInventory) {
				t.Fatalf("stale reply changed inventory: got %#v, want %#v", m.inventory, wantInventory)
			}
			if fmt.Sprint(m.inventoryErr) != fmt.Sprint(wantErr) {
				t.Fatalf("stale reply changed error: got %v, want %v", m.inventoryErr, wantErr)
			}
			if m.inventoryDiagnostic != wantDiagnostic || m.inventoryLoading != wantLoading {
				t.Fatalf("stale reply changed diagnostic/loading: diagnostic=%q loading=%t", m.inventoryDiagnostic, m.inventoryLoading)
			}
		})
	}
}

func TestRefreshInvalidatesPriorInventoryAndKeepsReplacementLazy(t *testing.T) {
	m := readyInventoryModel(100)
	cancelled := false
	m.inventoryGeneration, m.inventoryLoading = 11, true
	m.inventoryCancel = func() { cancelled = true }
	m = press(m, "r")
	if m.phase != loadingPlan || m.inventoryGeneration != 13 || !cancelled {
		t.Fatalf("refresh phase/generation/cancel = %v/%d/%t", m.phase, m.inventoryGeneration, cancelled)
	}

	replacement := m.plan
	next, cmd := m.Update(planMsg{plan: replacement})
	m = next.(model)
	if cmd != nil || m.inventoryRequested || m.inventoryLoading || m.inventoryGeneration != 14 {
		t.Fatalf("replacement inventory state requested/loading/generation/cmd = %t/%t/%d/%v",
			m.inventoryRequested, m.inventoryLoading, m.inventoryGeneration, cmd)
	}

	stale := []inventoryMsg{
		{
			revision: testRevision, generation: 11,
			inventory: inventorydata.Document{Capabilities: []inventorydata.Capability{{Name: "stale"}}},
		},
		{revision: testRevision, generation: 11, err: errors.New("stale failure"), diagnostic: "stale detail"},
	}
	for _, msg := range stale {
		next, _ = m.Update(msg)
		m = next.(model)
		if m.inventoryRequested || m.inventoryLoading || len(m.inventory.Capabilities) != 0 || m.inventoryErr != nil || m.inventoryDiagnostic != "" {
			t.Fatalf("stale reply mutated lazy replacement: requested=%t loading=%t inventory=%#v err=%v diagnostic=%q",
				m.inventoryRequested, m.inventoryLoading, m.inventory, m.inventoryErr, m.inventoryDiagnostic)
		}
	}
}

func TestEscapeCancelsConfirmationBeforeCapabilityNavigation(t *testing.T) {
	tests := []struct {
		name             string
		width            int
		focus            pane
		capabilitiesOpen bool
	}{
		{name: "narrow capability view", width: 72, focus: capabilityPane, capabilitiesOpen: true},
		{name: "wide capability focus", width: 140, focus: capabilityPane, capabilitiesOpen: true},
		{name: "wide preview focus", width: 140, focus: previewPane, capabilitiesOpen: true},
		{name: "narrow preview view", width: 72, focus: previewPane, capabilitiesOpen: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := readyInventoryModel(tt.width)
			m.phase, m.focus, m.capabilitiesOpen = confirming, tt.focus, tt.capabilitiesOpen
			m = press(m, "esc")
			if m.phase != ready {
				t.Fatalf("Escape left phase %v, want ready", m.phase)
			}
			if m.focus != tt.focus || m.capabilitiesOpen != tt.capabilitiesOpen {
				t.Fatalf("Escape navigated while cancelling: focus/open = %v/%t, want %v/%t",
					m.focus, m.capabilitiesOpen, tt.focus, tt.capabilitiesOpen)
			}
		})
	}
}

func TestInventoryFailureDiagnosticsAreExplicitSanitizedAndBounded(t *testing.T) {
	raw := strings.Join([]string{
		"\x1b]0;unsafe\x07FIRST DETAIL",
		"SECOND " + strings.Repeat("a", 100),
		"THIRD " + strings.Repeat("b", 100),
		"FOURTH " + strings.Repeat("c", 100),
		"FIFTH SECRET",
		"SIXTH SECRET",
	}, "\n")
	m := readyInventoryModel(100)
	m.inventory, m.inventoryRequested, m.inventoryLoading = inventorydata.Document{}, false, false
	m.inventoryGeneration = 5
	m.runner = runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(raw), errors.New("exit status 27")
	})
	cmd := m.startInventory()
	msg := cmd().(inventoryMsg)
	if msg.err == nil || msg.err.Error() != "inventory unavailable: exit status 27" {
		t.Fatalf("primary inventory error = %v", msg.err)
	}
	if strings.Contains(msg.err.Error(), "FIRST DETAIL") {
		t.Fatalf("primary error exposed command output: %q", msg.err)
	}
	if strings.ContainsAny(msg.diagnostic, "\x1b\a\r") {
		t.Fatalf("diagnostic retained terminal controls: %q", msg.diagnostic)
	}
	if lines := strings.Count(msg.diagnostic, "\n") + 1; lines > maxInventoryDiagnosticLines {
		t.Fatalf("diagnostic lines = %d, cap = %d", lines, maxInventoryDiagnosticLines)
	}
	if runes := len([]rune(msg.diagnostic)); runes > maxInventoryDiagnosticRunes {
		t.Fatalf("diagnostic runes = %d, cap = %d", runes, maxInventoryDiagnosticRunes)
	}
	if strings.Contains(msg.diagnostic, "FIFTH SECRET") {
		t.Fatalf("diagnostic exceeded line cap: %q", msg.diagnostic)
	}

	next, _ := m.Update(msg)
	m = next.(model)
	m.focus, m.capabilitiesOpen = capabilityPane, true
	primary := stripTerminalControls(strings.Join(m.capabilityRowsForWidth(60), "\n"))
	for _, want := range []string{"Inventory unavailable", "exit status 27", "Press d to show bounded diagnostic detail"} {
		if !strings.Contains(primary, want) {
			t.Errorf("primary failure missing %q: %q", want, primary)
		}
	}
	for _, rawLine := range []string{"FIRST DETAIL", "SECOND", "THIRD", "FOURTH", "FIFTH SECRET", "SIXTH SECRET"} {
		if strings.Contains(primary, rawLine) {
			t.Fatalf("primary failure exposed raw diagnostic %q: %q", rawLine, primary)
		}
	}

	m = press(m, "d")
	if !m.inventoryDetailsOpen || m.details {
		t.Fatalf("capability diagnostic toggle conflicted with preview details: diagnostic=%t preview=%t", m.inventoryDetailsOpen, m.details)
	}
	detail := stripTerminalControls(strings.Join(m.capabilityRowsForWidth(60), "\n"))
	if !strings.Contains(detail, "Diagnostic detail") || !strings.Contains(detail, "FIRST DETAIL") || strings.Contains(detail, "FIFTH SECRET") {
		t.Fatalf("requested diagnostic detail = %q", detail)
	}

	previewFocused := m
	previewFocused.focus, previewFocused.inventoryDetailsOpen = previewPane, false
	previewFocused = press(previewFocused, "d")
	if !previewFocused.details || previewFocused.inventoryDetailsOpen {
		t.Fatal("preview details key opened inventory diagnostics")
	}

	applies := 0
	m.apply = func(string, ...string) tea.Cmd {
		applies++
		return func() tea.Msg { return applyDoneMsg{} }
	}
	m = press(m, "enter")
	if m.phase != confirming {
		t.Fatal("inventory diagnostic view blocked apply confirmation")
	}
	m = press(m, "d")
	if m.phase != confirming {
		t.Fatal("diagnostic toggle cancelled apply confirmation")
	}
	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	m = next.(model)
	if m.phase != applying || applies != 1 || cmd == nil {
		t.Fatalf("diagnostic view blocked confirmed apply: phase=%v applies=%d", m.phase, applies)
	}
}
