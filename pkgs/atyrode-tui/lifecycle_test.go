package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func lifecycleTestModel(t *testing.T, runner commandRunner) model {
	t.Helper()
	m := newModel("atyrode")
	m.runner = runner
	m.nav.Select(workspaceLifecycle)
	return m
}

func generationJSON() []byte {
	return []byte(`[
		{"generation":42,"date":"2026-07-14 10:00:00","current":false,"closureSize":"1.2 GiB"},
		{"generation":43,"date":"2026-07-15 10:00:00","current":true}
	]`)
}

func runLifecycleCmd(t *testing.T, m *model, cmd tea.Cmd) {
	t.Helper()
	if cmd == nil {
		t.Fatal("expected lifecycle command")
	}
	updated, _ := m.Update(cmd())
	*m = updated.(model)
}

func TestLifecycleRollbackPreviewsBeforeExactMutation(t *testing.T) {
	var calls [][]string
	m := lifecycleTestModel(t, runnerFunc(func(_ context.Context, _ string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		switch len(calls) {
		case 1:
			return generationJSON(), nil
		case 2:
			if !reflect.DeepEqual(args, []string{"rollback", "--to", "42", "--dry-run"}) {
				t.Fatalf("preview arguments = %#v", args)
			}
			return []byte("would activate 42"), nil
		case 3:
			if !reflect.DeepEqual(args, []string{"rollback", "--to", "42", "--yes"}) {
				t.Fatalf("mutation arguments = %#v", args)
			}
			return []byte("activated 42"), nil
		default:
			t.Fatalf("unexpected command %#v", args)
			return nil, nil
		}
	}))

	runLifecycleCmd(t, &m, m.loadLifecycle())
	if m.lifecyclePhase != lifecycleBrowsing {
		t.Fatalf("phase after load = %v", m.lifecyclePhase)
	}
	runLifecycleCmd(t, &m, m.lifecycleUpdate("r"))
	if m.lifecyclePhase != lifecycleRollbackConfirming || !strings.Contains(m.lifecyclePreview, "would activate") {
		t.Fatalf("rollback preview state = phase %v preview %q", m.lifecyclePhase, m.lifecyclePreview)
	}
	if len(calls) != 2 {
		t.Fatalf("calls before confirmation = %#v", calls)
	}
	runLifecycleCmd(t, &m, m.lifecycleUpdate("y"))
	if m.lifecyclePhase != lifecycleSucceeded || m.lifecycleStatus != "Rolled back to generation 42." {
		t.Fatalf("rollback result = phase %v status %q", m.lifecyclePhase, m.lifecycleStatus)
	}
}

func TestLifecycleCancelAndCurrentGenerationHaveNoSideEffects(t *testing.T) {
	calls := 0
	m := lifecycleTestModel(t, runnerFunc(func(_ context.Context, _ string, args ...string) ([]byte, error) {
		calls++
		return generationJSON(), nil
	}))
	runLifecycleCmd(t, &m, m.loadLifecycle())
	m.lifecycleCursor = 1 // current generation
	if cmd := m.lifecycleUpdate("r"); cmd != nil {
		t.Fatal("current generation scheduled rollback preview")
	}
	if calls != 1 {
		t.Fatalf("current generation commands = %d, want only load", calls)
	}
	m.lifecycleCursor = 0
	m.lifecyclePhase = lifecycleRollbackConfirming
	m.lifecycleTarget = 42
	if cmd := m.lifecycleUpdate("n"); cmd != nil {
		t.Fatal("cancel scheduled mutation")
	}
	if calls != 1 || m.lifecyclePhase != lifecycleBrowsing {
		t.Fatalf("cancel state: calls=%d phase=%v", calls, m.lifecyclePhase)
	}
}

func TestLifecycleCleanUsesPreviewPolicyExactly(t *testing.T) {
	var calls [][]string
	m := lifecycleTestModel(t, runnerFunc(func(_ context.Context, _ string, args ...string) ([]byte, error) {
		calls = append(calls, append([]string(nil), args...))
		if len(calls) == 1 {
			if !reflect.DeepEqual(args, []string{"clean", "--dry-run", "--json"}) {
				t.Fatalf("clean preview arguments = %#v", args)
			}
			return []byte(`{"scope":"user","platform":"linux","profile":"/nix/var/nix/profiles/per-user/alex/home-manager","keep":7,"keepSince":"45d","dryRun":true,"generations":{"total":3,"candidates":1},"reclaimCandidates":[{"generation":2,"date":"2026-01-01 00:00:00","closureSize":"800 MiB"}],"note":"sizes may overlap"}`), nil
		}
		if !reflect.DeepEqual(args, []string{"clean", "--keep", "7", "--keep-since", "45d", "--yes"}) {
			t.Fatalf("clean mutation arguments = %#v", args)
		}
		for _, arg := range args {
			if arg == "--all" {
				t.Fatal("clean mutation must never pass --all")
			}
		}
		return []byte("cleaned"), nil
	}))

	runLifecycleCmd(t, &m, m.lifecycleUpdate("c"))
	if m.lifecyclePhase != lifecycleCleanConfirming {
		t.Fatalf("clean preview phase = %v", m.lifecyclePhase)
	}
	runLifecycleCmd(t, &m, m.lifecycleUpdate("y"))
	if len(calls) != 2 || m.lifecyclePhase != lifecycleSucceeded {
		t.Fatalf("clean result calls=%#v phase=%v", calls, m.lifecyclePhase)
	}
}

func TestLifecycleStaleAndFailureRepliesStayLocal(t *testing.T) {
	m := lifecycleTestModel(t, runnerFunc(func(context.Context, string, ...string) ([]byte, error) { return nil, nil }))
	m.lifecycleGeneration = 4
	m.generations = []generation{{Generation: 9, Date: "today"}}
	m.handleLifecycleMsg(lifecycleMsg{generation: 3, action: loadGenerations, generations: []generation{{Generation: 1, Date: "old"}}})
	if m.generations[0].Generation != 9 {
		t.Fatal("stale lifecycle reply replaced data")
	}
	m.handleLifecycleMsg(lifecycleMsg{generation: 4, action: previewClean, err: errors.New("nh unavailable")})
	if m.lifecyclePhase != lifecycleFailed || !strings.Contains(m.lifecycleErr.Error(), "nh unavailable") {
		t.Fatalf("failure not retained locally: phase=%v err=%v", m.lifecyclePhase, m.lifecycleErr)
	}
}

func TestConfirmedLifecycleMutationCannotBeCancelledOrQuit(t *testing.T) {
	cancelled := false
	m := lifecycleTestModel(t, runnerFunc(func(context.Context, string, ...string) ([]byte, error) { return nil, nil }))
	m.lifecyclePhase = lifecycleMutating
	m.lifecycleCancel = func() { cancelled = true }

	if cmd := m.lifecycleUpdate("n"); cmd != nil {
		t.Fatal("n scheduled work during confirmed mutation")
	}
	if cancelled || m.lifecyclePhase != lifecycleMutating {
		t.Fatalf("n interrupted confirmed mutation: cancelled=%t phase=%v", cancelled, m.lifecyclePhase)
	}
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'q'}})
	m = next.(model)
	if cancelled || cmd != nil || m.lifecyclePhase != lifecycleMutating {
		t.Fatalf("q interrupted confirmed mutation: cancelled=%t cmd=%v phase=%v", cancelled, cmd, m.lifecyclePhase)
	}
	next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = next.(model)
	if cmd != nil || m.nav.Active() != workspaceLifecycle {
		t.Fatalf("Tab left confirmed mutation: active=%q cmd=%v", m.nav.Active(), cmd)
	}
}

func TestLifecycleSuccessReloadsAuthoritativeGenerations(t *testing.T) {
	m := lifecycleTestModel(t, runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(`[
			{"generation":42,"date":"2026-07-14 10:00:00","current":true},
			{"generation":43,"date":"2026-07-15 10:00:00","current":false}
		]`), nil
	}))
	m.lifecycleGeneration = 7
	m.lifecyclePhase = lifecycleMutating
	m.lifecycleTarget = 42
	m.generations = []generation{{Generation: 42, Date: "old", Current: false}, {Generation: 43, Date: "old", Current: true}}

	cmd := m.handleLifecycleMsg(lifecycleMsg{generation: 7, action: executeRollback, output: "activated"})
	if cmd == nil || !m.lifecycleLoading {
		t.Fatalf("successful mutation did not start refresh: cmd=%v loading=%t", cmd, m.lifecycleLoading)
	}
	next, _ := m.Update(cmd())
	m = next.(model)
	if len(m.generations) != 2 || !m.generations[0].Current || m.generations[1].Current {
		t.Fatalf("authoritative generations were not refreshed: %#v", m.generations)
	}
}

func TestLifecycleRefreshFailurePreservesSuccessfulMutation(t *testing.T) {
	m := lifecycleTestModel(t, runnerFunc(func(context.Context, string, ...string) ([]byte, error) {
		return nil, errors.New("inventory unavailable")
	}))
	m.lifecycleGeneration = 9
	m.lifecyclePhase = lifecycleMutating
	m.lifecycleTarget = 42

	cmd := m.handleLifecycleMsg(lifecycleMsg{generation: 9, action: executeRollback, output: "activated"})
	next, _ := m.Update(cmd())
	m = next.(model)
	if m.lifecyclePhase != lifecycleSucceeded || m.lifecycleErr != nil {
		t.Fatalf("refresh failure replaced mutation success: phase=%v err=%v", m.lifecyclePhase, m.lifecycleErr)
	}
	for _, want := range []string{"Rolled back to generation 42.", "Refresh failed:", "inventory unavailable"} {
		if !strings.Contains(m.lifecycleStatus, want) {
			t.Fatalf("mutation status missing %q: %q", want, m.lifecycleStatus)
		}
	}
}

func TestLifecycleRenderingIsBounded(t *testing.T) {
	m := lifecycleTestModel(t, runnerFunc(func(context.Context, string, ...string) ([]byte, error) { return nil, nil }))
	m.width, m.height = 44, 12
	m.lifecyclePhase = lifecycleCleanConfirming
	m.clean = cleanPreview{Keep: 5, KeepSince: "30d", DryRun: true, ReclaimCandidates: []cleanCandidate{{Generation: 12, Date: strings.Repeat("long-date ", 12), ClosureSize: strings.Repeat("large ", 10)}}}
	for _, line := range strings.Split(m.lifecycleView(40), "\n") {
		if lipgloss.Width(line) > 40 {
			t.Fatalf("rendered line width %d exceeds panel width: %q", lipgloss.Width(line), line)
		}
	}
}
